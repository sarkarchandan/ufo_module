#!/bin/bash

set -e

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="${SOURCE_DIR:-/tmp/build}"
CONFIG_FILE="$SCRIPT_DIR/ufo.cfg"
DEPS_FILE="$SCRIPT_DIR/ufo.deps"
INCLUDE_DEPS="${INCLUDE_DEPS:-false}"
KEEP_BUILD_DIRS="${KEEP_BUILD_DIRS:-false}"

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Options:
    --include-deps         Check and install dependencies (default: skip)
    --keep-build-dirs      Keep build directories after installation (default: remove)
    -h, --help             Show this help message

EOF
    exit "$1"
}

log_info() {
    echo "[INFO] $*"
}

log_error() {
    echo "[ERROR] $*" >&2
}

check_compute_environment() {
    log_info "=== Compute Environment ==="

    if ! command -v nvidia-smi &>/dev/null; then
        log_error "nvidia-smi not found. NVIDIA driver is required."
        exit 1
    fi

    log_info "GPUs detected:"
    while IFS=, read -r name driver memory; do
        name=$(echo "$name" | xargs)
        driver=$(echo "$driver" | xargs)
        memory=$(echo "$memory" | xargs)
        log_info "  - $name | Driver: $driver | Memory: $memory"
    done < <(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null)

    if command -v clinfo &>/dev/null; then
        local opencl_version
        opencl_version=$(clinfo 2>/dev/null | grep -m1 "OpenCL.*CUDA" | awk -F: '{print $2}' | xargs)
        if [[ -n "$opencl_version" ]]; then
            log_info "OpenCL: $opencl_version"
        fi
    fi

    log_info "============================"
}

setup_ufo_environment() {
    log_info "=== Setting UFO Environment ==="

    export LD_LIBRARY_PATH="$UFO_ROOT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export GI_TYPELIB_PATH="$UFO_ROOT/lib/girepository-1.0${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
    export PKG_CONFIG_PATH="$UFO_ROOT/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

    log_info "  LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
    log_info "  GI_TYPELIB_PATH=$GI_TYPELIB_PATH"
    log_info "  PKG_CONFIG_PATH=$PKG_CONFIG_PATH"

    log_info "==============================="
}

validate_ufo_core_install() {
    log_info "Validating ufo-core installation..."

    if ! pkg-config --exists ufo 2>/dev/null; then
        log_error "pkg-config --exists ufo failed"
        return 1
    fi

    local version
    version=$(pkg-config --modversion ufo 2>/dev/null)
    if [[ -z "$version" ]]; then
        log_error "pkg-config --modversion ufo returned empty"
        return 1
    fi

    log_info "ufo-core validation passed (version: $version)"
    return 0
}

install_ufo_core_python_bindings() {
    local python_dir="$1"

    log_info "Installing ufo-core Python bindings from $python_dir"
    log_info "Command: cd $python_dir && pip install . --prefix=$UFO_ROOT --no-deps"

    if ! (cd "$python_dir" && pip install . --prefix="$UFO_ROOT" --no-deps); then
        log_error "pip install failed for ufo-core Python bindings"
        return 1
    fi

    log_info "ufo-core Python bindings installed successfully"
    return 0
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    source "$CONFIG_FILE"

    if [[ -z "$UFO_ROOT" ]]; then
        log_error "UFO_ROOT not set in config file"
        exit 1
    fi

    log_info "Loaded configuration from $CONFIG_FILE"
    log_info "  UFO_ROOT=$UFO_ROOT"
    log_info "  REL_UFO_CORE=$REL_UFO_CORE"
    log_info "  REL_UFO_FILTERS=$REL_UFO_FILTERS"
    log_info "  REL_TOFU=$REL_TOFU"
}

check_dependency() {
    local pkg="$1"
    if apt list --installed 2>/dev/null | grep -q "^$pkg/"; then
        return 0
    else
        return 1
    fi
}

install_dependencies() {
    if [[ ! -f "$DEPS_FILE" ]]; then
        log_error "Dependencies file not found: $DEPS_FILE"
        exit 1
    fi

    log_info "Reading dependencies from $DEPS_FILE"

    local missing_deps=()
    while IFS= read -r dep || [[ -n "$dep" ]]; do
        dep=$(echo "$dep" | tr -d '[:space:]')
        [[ -z "$dep" ]] && continue
        [[ "$dep" =~ ^# ]] && continue

        if ! check_dependency "$dep"; then
            missing_deps+=("$dep")
        else
            log_info "  $dep - already installed"
        fi
    done < "$DEPS_FILE"

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_info "Installing missing dependencies: ${missing_deps[*]}"
        apt-get update
        apt-get install -y "${missing_deps[@]}"
    else
        log_info "All dependencies are already installed"
    fi
}

cleanup() {
    local exit_code=$?

    if [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]]; then
        if [[ "$KEEP_BUILD_DIRS" != "true" ]]; then
            log_info "Cleaning up build directory: $BUILD_DIR"
            rm -rf "$BUILD_DIR"
        else
            log_info "Keeping build directory: $BUILD_DIR"
        fi
    fi
    exit $exit_code
}

clone_repo() {
    local repo_url="$1"
    local repo_name="$2"
    local tag="$3"
    local dest_dir="$4"

    log_info "Cloning $repo_name tag $tag into $dest_dir"
    log_info "Command: git clone --depth 1 --branch $tag $repo_url $dest_dir"

    if ! git clone --depth 1 --branch "$tag" "$repo_url" "$dest_dir" 2>&1; then
        log_error "Failed to clone $repo_name tag $tag"
        return 1
    fi

    log_info "Successfully cloned $repo_name"
    return 0
}

build_and_install() {
    local repo_name="$1"
    local repo_dir="$2"
    local build_subdir="$3"
    local install_root="$4"
    shift 4
    local -a extra_meson_flags=("$@")

    log_info "Building $repo_name"

    log_info "Command: cd $repo_dir && CFLAGS=-w CXXFLAGS=-w meson $build_subdir --prefix=$install_root --libdir=lib ${extra_meson_flags[*]}"
    if ! (cd "$repo_dir" && CFLAGS=-w CXXFLAGS=-w meson "$build_subdir" --prefix="$install_root" --libdir=lib "${extra_meson_flags[@]}"); then
        log_error "Meson build failed for $repo_name"
        return 1
    fi

    log_info "Command: cd $repo_dir && ninja -C $build_subdir"
    if ! (cd "$repo_dir" && ninja -C "$build_subdir"); then
        log_error "Ninja build failed for $repo_name"
        return 1
    fi

    log_info "Command: cd $repo_dir && ninja -C $build_subdir install"
    if ! (cd "$repo_dir" && ninja -C "$build_subdir" install); then
        log_error "Ninja install failed for $repo_name"
        return 1
    fi

    log_info "Successfully built and installed $repo_name"
    return 0
}

install_tofu() {
    local tofu_dir="$1"
    local install_root="$2"

    log_info "Building and installing tofu (Python package)"
    log_info "Command: cd $tofu_dir && pip install . --prefix=$install_root --no-deps"

    if ! (cd "$tofu_dir" && pip install . --prefix="$install_root" --no-deps --upgrade); then
        log_error "pip install failed for tofu"
        return 1
    fi

    log_info "Successfully installed tofu"
    return 0
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --include-deps)
                INCLUDE_DEPS=true
                shift
                ;;
            --keep-build-dirs)
                KEEP_BUILD_DIRS=true
                shift
                ;;
            -h|--help)
                usage 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage 1
                ;;
        esac
    done

    load_config
    check_compute_environment

    if [[ "$INCLUDE_DEPS" == "true" ]]; then
        install_dependencies
    else
        log_info "Dependencies check skipped"
    fi

    log_info "Creating build directory"
    BUILD_DIR=$(mktemp -d -p "$SCRIPT_DIR" ufo-build-XXXXXX)
    log_info "Build directory: $BUILD_DIR"

    trap cleanup EXIT

    UFO_CORE_DIR="$BUILD_DIR/ufo-core"
    UFO_FILTERS_DIR="$BUILD_DIR/ufo-filters"
    TOFU_DIR="$BUILD_DIR/tofu"

    if ! clone_repo "https://github.com/ufo-kit/ufo-core.git" "ufo-core" "$REL_UFO_CORE" "$UFO_CORE_DIR"; then
        log_error "Failed to clone ufo-core"
        exit 1
    fi

    if ! build_and_install "ufo-core" "$UFO_CORE_DIR" "build" "$UFO_ROOT" \
        "-Dgtk_doc=False" \
        "-Dbashcompletiondir=$UFO_ROOT/share/bash-completion/completions"; then
        log_error "Failed to build and install ufo-core"
        exit 1
    fi

    setup_ufo_environment

    if ! validate_ufo_core_install; then
        log_error "ufo-core installation validation failed"
        exit 1
    fi

    if ! install_ufo_core_python_bindings "$UFO_CORE_DIR/python"; then
        log_error "Failed to install ufo-core Python bindings"
        exit 1
    fi

    if ! clone_repo "https://github.com/ufo-kit/ufo-filters.git" "ufo-filters" "$REL_UFO_FILTERS" "$UFO_FILTERS_DIR"; then
        log_error "Failed to clone ufo-filters"
        exit 1
    fi

    if ! build_and_install "ufo-filters" "$UFO_FILTERS_DIR" "build" "$UFO_ROOT" \
        "-Dcontrib_filters=True" \
        "-Ddocs=False"; then
        log_error "Failed to build and install ufo-filters"
        exit 1
    fi

    if ! clone_repo "https://github.com/ufo-kit/tofu.git" "tofu" "$REL_TOFU" "$TOFU_DIR"; then
        log_error "Failed to clone tofu"
        exit 1
    fi

    if ! install_tofu "$TOFU_DIR" "$UFO_ROOT"; then
        log_error "Failed to install tofu"
        exit 1
    fi

    log_info "Installation completed successfully"
    log_info "Software installed to: $UFO_ROOT"
}

main "$@"

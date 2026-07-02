# UFO Install Script


## Install instructions

- Change UFO\_ROOT at ufo.cfg to appropriate path for Maxwell.
- Change UFO\_ROOT at modulefile to appropriate path for Maxwell. 

To verify that the ufo-installation actually worked we can execute the following script and see if it exits with code 0.

```bash
ufo-launch dummy-data height=2016 width=2016 ! fft dimensions=1 ! ifft ! null download=true finish=true
```

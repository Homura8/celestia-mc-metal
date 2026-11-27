# Cloud noise textures

These three files come from Photon Shaders (https://github.com/sixthsurge/photon), commit 26c2906e, the last commit released under the MIT License. They are © 2025 Benjamin Stott ("sixthsurge"); the full licence text is in `LICENSES/MIT-Photon.txt`.

| File | Format | Used for |
| --- | --- | --- |
| `photon_noise.png` (upstream `image/noise.png`) | 512×512 RGBA8 | Cloud coverage (R) and per-cloud shape (A) |
| `photon_worley.dat` (upstream `image/worley_noise.dat`) | 64×64×64 R8, x fastest | Cloud detail erosion |
| `photon_curl.dat` (upstream `image/curl_noise.dat`) | 32×32×32 RGB8, x fastest | Swirling the detail noise |

The files are unmodified. `ShadeCloudNoise` packs the two volumes into tiled 2D atlases with a one-texel wrap gutter at load time.

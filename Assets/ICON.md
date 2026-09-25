# App icon

`AppIcon.png` is the approved artwork: a compact 3D keyboard joining a blue waveform on textured black paper. The app and website use this same image. The accent colour is `#0050ff`.

`scripts/build-icon.sh` generates the macOS icon sizes. The app version and build number appear in the bundled ICNS filename to invalidate icon caches. When changing the icon, increase those values in `scripts/build-app.sh` and the website icon filename. Keep only the current artwork in the working tree.

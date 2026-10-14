# DoorBoss — hosted builds

- `index.html` — demo build (sample Aurora data, local storage). Open on a phone: https://cryptouprise.github.io/doorboss/
- `index.prod.html` — production build (expects the DoorBoss backend at /api/*). This is the file AI Studio pulls in for the /doors page.
- `sw.js`, `manifest.json`, icons — service worker and home-screen install.

Source and build: Cryptouprise/doorboss (app/src, `node build.js --site [--prod]`).

# Native remote-browser acceptance

This harness starts the production Flutter HTTP/WebSocket/APRS handlers in a
fresh test process, then uses a separate temporary Edge profile. It never opens
Bluetooth, a real radio, a physical microphone or real RF/PTT/beacon transmission.
Browser microphone and geolocation data are synthetic. It checks native
permission denial/grant, independent operation rights, emergency stop, local
microphone cleanup/no upload, authenticated manifest loading, decoded icons,
PWA installation and an actual standalone application window, and fullscreen.

On Windows with Flutter, Node.js and Edge installed:

```powershell
npm ci --prefix tools/browser-acceptance --ignore-scripts --no-audit --no-fund
node tools/browser-acceptance/run.cjs
```

The full test opens isolated browser/application windows and removes the test
PWA/profile afterwards. Windows CI runs it on the build VM before publishing a
release, so it does not open windows on the developer's computer. The workflow
uploads the result JSON, screenshots and fixture log, excluding the profile and
its synthetic cookies.

For background local development use `--headless`. This checks the browser
permission/media/install/manifest paths, but **explicitly skips standalone-window
acceptance**; headless results cannot satisfy that gate. Override the Flutter
command with `HTC_FLUTTER_BINARY` and optional evidence parent directory with
`HTC_BROWSER_OUTPUT`. Every execution creates fresh state and a fresh profile.
No user preferences are loaded; input and simulated operations never reach a
hardware transport. Real phone GPS accuracy/audio and mobile-browser behavior
are separate physical compatibility checks.

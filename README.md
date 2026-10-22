# Stillwater Row

A 3D river for a home rowing machine: race a ghost of your previous sessions, hit split milestones, unlock achievements.

- Live: https://slaskis.github.io/stillwater-row/
- Single static file (`index.html`), Three.js from cdnjs, sessions kept in the browser's localStorage.
- Rower link over Web Bluetooth: FitShow consoles (`FS-…`, service `FFF0`) and standard FTMS (`0x1826`).
  On iPad, open it in a Web Bluetooth browser such as Bluefy (Safari has no Web Bluetooth).
- Without a rower connected: tap the screen or press Space once per stroke.

FitShow framing (`02 cmd … xor 03`, polls `02 42 42 03` / `02 43 01 42 03`) follows the
FitShow rower driver in [qdomyos-zwift](https://github.com/cagnulein/qdomyos-zwift/pull/4919).

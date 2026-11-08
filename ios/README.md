# Stillwater Row for iPad and iPhone

A native rewrite of Stillwater Row in SwiftUI, SceneKit and SwiftData, with Apple Health.

## What's in this first version

- **Rower link over Bluetooth:** FitShow consoles such as the Trekkrunner TR020 (`FS-…`), plus standard FTMS rowers. The app remembers the console and reconnects on its own whenever it wakes up. Without a rower, tapping the screen once per stroke works.
- **3D river:** endless autumn river with spruce and birch, racing buoys, distance signs, milestone gates and a finish banner. The boat glides when you stop rowing.
- **Ghost racing:** race your best or your last row on the same piece, second by second, or a pace boat.
- **Pieces:** Just Row, 1,000 m, 2,000 m, 5,000 m and 20 minutes, with splits every 500 m.
- **Cox:** spoken start, splits, overtakes and the final stretch, using the best English voice installed on the device. Music only ducks while the cox is talking.
- **Apple Health:**
  - Each row is saved as an indoor rowing workout, with distance in 10-second slices and active energy.
  - Rowing from other apps is shown in the logbook.
  - Heart rate during each row is read from Health, whatever recorded it.
- **Heart rate:**
  - A Withings watch can't stream heart rate live. If you start a workout on the watch, it records every second, and the Withings app syncs that into Health afterwards.
  - The results screen shows heart rate once the sync has happened ("Check again").
  - Any standard Bluetooth chest strap or arm band gives live heart rate on screen.

The game features from the web version (fleet racing, storm, regatta season, journeys, shop and so on) aren't in this version yet. They'll be ported in stages.

## Build it

You need a Mac with Xcode 16 or later, and an iPad or iPhone on iOS 18 or later.

1. Install XcodeGen once: `brew install xcodegen`
2. In this folder, run `xcodegen`. That creates `StillwaterRow.xcodeproj` from `project.yml`.
3. Open the project. Under the StillwaterRow target, go to **Signing & Capabilities** and pick your team. A free personal team works, but the app then has to be reinstalled every 7 days; a paid developer account removes that limit. If Xcode says the bundle id is taken, change `se.middlemanagement.stillwater` to anything unique.
4. Connect the iPad, turn on Developer Mode on it if asked (Settings › Privacy & Security), select it as the run destination, and press Run.
5. On the iPad: open the app, go to **Rower › Find rower**, and pick `FS-…`. Then go to **Apple Health › Connect** and allow access.

Close the Synteam app before connecting, because the console only accepts one connection at a time.

Run the unit tests with ⌘U. They cover the FitShow and FTMS decoders, physics, splits and formatting.

## Layout

```
StillwaterRow/
  App/        app entry
  Core/       plain Swift: console protocols, physics, session clock, rivals, formatting (unit-tested)
  Platform/   CoreBluetooth link, HealthKit store, cox voice
  Scene/      SceneKit river, banks, trees, water shader, boats
  Game/       frame loop and race logic
  Data/       SwiftData model
  Views/      SwiftUI screens
```

`project.yml` is the source of truth for the Xcode project. `Info.plist` and the entitlements are generated from it, so edit the YAML and rerun `xcodegen`.

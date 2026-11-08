# Stillwater Row for iPad and iPhone

A native rewrite of Stillwater Row in SwiftUI, SceneKit and SwiftData, with Apple Health.

## What's in it

- **Rower link over Bluetooth:** FitShow consoles such as the Trekkrunner TR020 (`FS-…`), plus standard FTMS rowers. The app remembers the console and reconnects on its own whenever it wakes up. Without a rower, tapping the screen once per stroke works.
- **3D river:** endless autumn river with spruce and birch, racing buoys, distance signs, milestone gates and a finish banner. The boat glides when you stop rowing.
- **Ghost racing:** race your best or your last row on the same piece, second by second, or a pace boat.
- **Pieces:** Just Row, 1,000 m, 2,000 m, 5,000 m, 20 minutes, 4 × 500 m intervals, a 1-2-3-2-1 pyramid, and Outrun the storm.
- **Race the fleet:** six crews spread out ahead to reel in, worth points each time you pass one.
- **Outrun the storm:** a squall starts 80 m behind and keeps speeding up. The sky darkens, rain sets in and lightning flashes as it closes.
- **Speed gates:** every 400 m, beat a target split over the last 100 m. Hits in a row multiply the points; every fourth gate is gold.
- **Intervals:** targets set a little faster than your recent split, with the cox calling each rep and rest.
- **Power 10s and rhythm:** the cox calls a Power 10 every couple of minutes and scores the extra speed. A steady stroke rate fills the rhythm bar until you're in the zone.
- **Regatta season:** eight events from Söderköping to Stockholm, including duels with Old Man Svensson and Ingrid Holm, who talk back. Each medal unlocks the next event.
- **Journeys:** every metre counts towards rowing Göta kanal or out through the Stockholm archipelago, with stops along the way.
- **Progress:** points, XP, levels and ranks, coins, 21 milestones, a day streak and a daily challenge.
- **Cox:** spoken start, splits, overtakes and the final stretch, using the best English voice installed on the device. Music only ducks while the cox is talking.
- **Apple Health:**
  - Each row is saved as an indoor rowing workout, with distance in 10-second slices and active energy.
  - Rowing from other apps is shown in the logbook.
  - Heart rate during each row is read from Health, whatever recorded it.
- **Heart rate:**
  - A Withings watch can't stream heart rate live. If you start a workout on the watch, it records every second, and the Withings app syncs that into Health afterwards.
  - The results screen shows heart rate once the sync has happened ("Check again").
  - Any standard Bluetooth chest strap or arm band gives live heart rate on screen.

- **Weather and scenery:** dawn mist, clear day, sunset, night lanterns or autumn rain (or follow the clock), through a forest river or the archipelago, with swans, herons, birds, bridges, cottages, spars, sailing boats and a lighthouse.
- **Wildlife:** eight animals to spot for the field guide, and messages in bottles.
- **Boat shop:** spend coins on hats, crew, flags and wakes; liveries unlock with your level.
- **Music and sound:** a band that follows your stroke rate and gets busier as you push, plus splashes, gate dings, thunder, the start horn, a cheering grandstand, fireworks and an optional rate beat.

## Build it

You need a Mac with Xcode 16 or later, and an iPad or iPhone on iOS 18 or later.

1. Install XcodeGen once: `brew install xcodegen`
2. In this folder, run `xcodegen`. That creates `StillwaterRow.xcodeproj` from `project.yml`.
3. Open the project. Under the StillwaterRow target, go to **Signing & Capabilities** and pick your team. A free personal team works, but the app then has to be reinstalled every 7 days; a paid developer account removes that limit. If Xcode says the bundle id is taken, change `se.middlemanagement.stillwater` to anything unique.
4. Connect the iPad, turn on Developer Mode on it if asked (Settings › Privacy & Security), select it as the run destination, and press Run.
5. On the iPad: open the app, go to **Rower › Find rower**, and pick `FS-…`. Then go to **Apple Health › Connect** and allow access.

Close the Synteam app before connecting, because the console only accepts one connection at a time.

Run the unit tests with ⌘U. They cover the FitShow and FTMS decoders, physics, splits, formatting, and the fleet, storm, gates, intervals, season and level rules.

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

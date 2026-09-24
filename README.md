# SmartRingWatcher

A standalone Apple Watch app that connects directly to a smart ring over Bluetooth LE and shows its
health data on the watch. Values refresh automatically. It speaks the protocol of rings sold with the
**Smarthealth** app ([App Store](https://apps.apple.com/us/app/smarthealth/id1450500729), by Shenzhen
Yucheng Innovation Technology). It also falls back to the standard Bluetooth Heart Rate and Battery
services, so other generic rings show heart rate and battery too.

<p align="center"><img src="SmartRingWatcher%20Watch%20App/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="120" alt="App icon"></p>

## Metrics

| Metric | Where it comes from | On the watch |
|---|---|---|
| Heart rate | live snapshot, real-time upload, HR history, standard `0x2A37` | current, 24 h chart, min/avg/max, resting estimate, measure now |
| HRV | "all" history, body-data RMSSD/SDNN, RR intervals | latest, 24 h chart, SDNN, RMSSD, pNN50, LF/HF, VO₂max |
| Sleep | sleep history (per-stage records) | total asleep, bed and wake times, hypnogram, deep/light/REM/awake, times awake, score (est.), last 7 nights |
| Steps, distance, calories | live snapshot, sport history | today's ring vs. 10k goal, hourly bars, 7-day bars |
| Blood pressure | live snapshot, BP history, measurement results | latest with AHA category, 24 h range chart, measure now |
| Blood oxygen (SpO₂) | live snapshot, SpO₂ history | latest, 24 h chart, min/avg, measure now |
| Temperature | live snapshot, temperature history | latest (°C/°F), 24 h chart, measure now |
| Stress, fatigue, HRV index | body-data history/upload (the ring's own 0–10 indices) | stress 0–10 with level (lower HRV → higher stress), fatigue, HRV index, body index, sympathetic balance |
| Respiration rate | live snapshot, "all" history | latest, 24 h chart, measure now |
| Blood glucose, uric acid, ketone, lipids | blood-chemistry history (rings that support it) | shown only when the ring reports them |
| Ring battery, firmware | device info, standard Battery service | home screen and Ring page |

ECG is not listed: it is a feature of Smarthealth *watches*, and rings don't have the electrodes for it.

## Auto-refresh

* **While the app is open**, the ring's live snapshot is polled every 10 s (configurable: 5/10/30/60 s)
  and battery about once a minute. Stored history (sleep, steps, HR, BP, SpO₂, HRV, stress, temperature) is
  re-synced every 5 min (configurable). Anything the ring pushes by itself appears immediately, including
  real-time uploads and measurement results.
* **In the background**, the app schedules watchOS Background App Refresh (at most about 4 times an hour,
  with about 15 s each). It reconnects, pulls the live snapshot, battery, and HR and step history, and then
  schedules the next refresh.
* The **"… ago" labels** tick on their own, and the last data is cached on the watch, so the app opens with
  values even before the ring reconnects.
* **Optional:** Settings → *Stream live HR & steps* asks the ring to push values every 2 s. This uses more
  ring battery.

## Requirements

* Xcode 15 or newer (the project file uses the Xcode 14+ format, `objectVersion 56`)
* watchOS 10+ (Apple Watch Series 4 or later)
* A Smarthealth-compatible ring. The Yucheng `BE940000` service is used when present, otherwise
  Nordic UART, otherwise the standard Heart Rate and Battery services.

## Build and run

1. Open `SmartRingWatcher.xcodeproj`.
2. Select the **SmartRingWatcher Watch App** target → *Signing & Capabilities* → choose your team.
   Change the bundle identifier if Xcode asks (`com.example.SmartRingWatcher.watchkitapp`).
3. Pick your Apple Watch (or a watch simulator) as the run destination and press **Run**.
   * The **simulator has no Bluetooth**, so the app starts in **Demo mode** with generated data there.
     Turn it off in Settings on a real watch.
4. On the watch: tap the status row at the top → **Find rings** → tap your ring. It is remembered and
   reconnected automatically from then on.

> **One connection at a time.** Rings accept a single Bluetooth connection. If your ring doesn't appear,
> force-quit Smarthealth on the iPhone or briefly turn off the phone's Bluetooth. The watch app never
> deletes data from the ring, so Smarthealth still receives the full history when it reconnects.

## Project layout

```
RingProtocol/                   Pure-Swift protocol layer (no Bluetooth): frames, CRC, parsers,
                                history-transfer handshake. Shared by the app and the unit tests.
SmartRingWatcher Watch App/
  App/                          @main app, background refresh (WKApplicationDelegate)
  BLE/RingBluetoothManager      CoreBluetooth: scan, connect, auto-reconnect, subscribe, write queue
  BLE/RingSyncEngine            command queue, auto-refresh timers, history sync, measurements
  Store/HealthDataStore         merged, de-duplicated samples (14 days), JSON cache, derived stats
  Store/AppSettings, DemoData   preferences; generated data for the simulator
  Views/                        home list, one detail page per metric, ring pairing, settings
Tests/RingProtocolTests/        XCTest suite (vectors cross-checked against the vendor SDK)
docs/PROTOCOL.md                protocol reference with sources
tools/generate_xcodeproj.py     regenerates the Xcode project after adding or removing files
```

## Tests

The protocol layer is plain Foundation code, so it can be tested on a Mac without a watch or ring:

```sh
swift test
```

Expected byte values in the tests were produced by running the vendor's own SDK code on the JVM.
This covers the CRC, command framing, and every history record type.

## Adding files

The Xcode project is generated. After adding or removing a Swift file, run:

```sh
python3 tools/generate_xcodeproj.py
```

## Notes and limitations

* The protocol comes from the vendor SDK and community reverse engineering. Firmware differs between ring
  models, so a ring may not support every query. Unsupported ones are skipped automatically; see
  Settings → Diagnostics.
* Cuffless blood pressure, blood chemistry and the sleep score are **estimates**, not medical measurements.
  Smarthealth's own sleep score is computed in its cloud service, so this app shows a transparent estimate
  (duration, deep %, REM % and efficiency).
* The project has a single watch-only target, which is enough to run on your own watch from Xcode. App
  Store or TestFlight distribution of a watch-only app also needs Xcode's watch-app container target.

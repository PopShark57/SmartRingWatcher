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
| HRV | "all" history, body-data RMSSD/SDNN, RR intervals (60 s window) | latest and 24 h chart of one measure (RMSSD, else SDNN, else the ring's own value), SDNN, RMSSD, pNN50, LF/HF, VO₂max |
| Sleep | sleep history (per-stage records) | total asleep, bed and wake times, hypnogram, deep/light/REM/awake, times awake, score (est.), last 7 nights |
| Steps, distance, calories | live snapshot, sport history | today's ring vs. your step goal, hourly bars, 7-day bars |
| Blood pressure | live snapshot, BP history, measurement results | latest with ACC/AHA category, 24 h range chart, measure now |
| Blood oxygen (SpO₂) | live snapshot, SpO₂ history | latest, 24 h chart, min/avg, measure now |
| Temperature | live snapshot, temperature history | latest (°C/°F), 24 h chart, measure now |
| Stress, fatigue, HRV index | body-data history/upload (the ring's own 0–10 indices) | stress 0–10 with level (lower HRV → higher stress), fatigue, HRV index, body index, sympathetic balance |
| Respiration rate | live snapshot, "all" history | latest, 24 h chart, measure now |
| Blood glucose, uric acid, ketone, lipids | blood-chemistry history (rings that support it) | hidden unless you opt in (Settings → Blood chemistry); never classified or written to Health |
| Ring battery, firmware | device info, standard Battery service | home screen and Ring page |

ECG is not listed: it is a feature of Smarthealth *watches*, and rings don't have the electrodes for it.

## Auto-refresh

* **While the app is open**, the ring's live snapshot is polled every 10 s (configurable: 5/10/30/60 s)
  and battery about once a minute. Anything the ring pushes by itself appears immediately, including
  real-time uploads and measurement results.
* **History is pulled per type.** The app never deletes history from the ring (so Smarthealth still gets
  it), so the ring resends everything it holds on each request. Each type is therefore pulled only as often
  as it is useful:
  * heart rate, steps and the combined record: every 15 min (configurable: 5/15/30/60 min);
  * blood pressure, SpO₂, temperature and body data: about every 45 min;
  * sleep: once in the morning (after 06:00), then hourly until last night's sleep has arrived;
  * blood chemistry: only if you opted in, and right after a measurement.

  *Sync now* and pull-to-refresh fetch everything. Settings → Diagnostics shows the size of each transfer.
* **In the background**, the app schedules watchOS Background App Refresh (about 15 s each). It reconnects,
  pulls the live snapshot, battery, and heart-rate and step history, updates the complication, and schedules
  the next refresh. watchOS allows up to about **four refreshes an hour only while the SmartRing
  complication is on the active watch face**; without it the app gets fewer. The `bluetooth-central`
  background mode can also wake the app when the ring sends data, but watchOS caps those wake-ups (a handful
  a day), so live streaming is switched off whenever the app leaves the screen.
* Values show their age ("5 minutes ago"), dim after 6 hours and get a clock badge after a day. A value the
  ring merely repeats in a poll keeps the time it was first seen. The last data is cached on the watch, so
  the app opens with values even before the ring reconnects.
* **Optional:** Settings → *Stream live HR & steps* asks the ring to push values every 2 s. This uses more
  ring battery.

## Complication and Smart Stack

Add **SmartRing** to a watch face (or the Smart Stack) for the latest heart rate and its age, today's steps
against your goal, and ring battery. Keeping it on the active face is also what earns the app its
background-refresh budget.

## Apple Health and notifications

* Settings → **Save to Health** writes heart rate, HRV (SDNN only, which is what HealthKit's HRV type
  stores), blood oxygen, respiration, blood pressure, steps, distance, active energy and sleep stages, with
  the ring as the source device. Every sample has a sync identifier, so re-downloaded history never
  duplicates. Temperature (finger skin, not body temperature) and blood chemistry are never written.
* Settings → **Notifications** (all off by default): ring battery at 15 % or less, ring not seen for a day,
  and a measurement that finished while the app was in the background.

## Requirements

* Xcode 16 or newer (the project uses buildable folders, `objectVersion 77`, and Swift 6 language mode)
* watchOS 10+ (Apple Watch Series 4 or later)
* A Smarthealth-compatible ring. The Yucheng `BE940000` service is used when present, otherwise
  Nordic UART, otherwise the standard Heart Rate and Battery services.

## Build and run

1. Open `SmartRingWatcher.xcodeproj`.
2. Choose your team under *Signing & Capabilities* for both targets (**SmartRingWatcher Watch App** and
   **SmartRingWatcher Widget**). To use your own identifiers, change one project build setting,
   `RING_BUNDLE_ID_PREFIX` (default `com.example.SmartRingWatcher`); the app, the widget and the App Group
   (`group.<prefix>`) all follow it.
   * The app uses the **App Groups** capability (shared with the complication) and **HealthKit**. Xcode
     registers them for a paid developer team. A free personal team may not support App Groups; if signing
     fails, remove `CODE_SIGN_ENTITLEMENTS` from both targets. The app still works, but the complication
     then has no data and Health export is unavailable.
3. Pick your Apple Watch (or a watch simulator) as the run destination and press **Run**.
   * The **simulator has no Bluetooth**, so the app starts in **Demo mode** with generated data there.
     Turn it off in Settings on a real watch.
4. On the watch: tap **Pair your ring** (or the status row at the top) → **Find rings** → tap your ring.
   It is remembered and reconnected automatically from then on. **Disconnect** pauses that until you tap
   **Reconnect**, so Smarthealth on the phone can connect in the meantime.

> **One connection at a time.** Rings accept a single Bluetooth connection. If your ring doesn't appear,
> force-quit Smarthealth on the iPhone or briefly turn off the phone's Bluetooth. The watch app never
> deletes data from the ring, so Smarthealth still receives the full history when it reconnects.

## Project layout

```
RingProtocol/                   Pure-Swift protocol layer (no Bluetooth): frames, CRC, parsers,
                                history-transfer handshake, RR-interval window.
SmartRingWatcher Watch App/
  App/                          @main app, AppModel wiring, background refresh (WKApplicationDelegate)
  Core/                         UI-free logic, also compiled by `swift test`:
    RingSyncEngine              command queue, per-type history schedule, retries, measurements
    HealthDataStore             merged, de-duplicated samples (14 days), cached derived values, JSON cache
    AppSettings, DemoData, …    preferences; generated data; clock/timer and transport abstractions
  BLE/RingBluetoothManager      CoreBluetooth: scan, connect, pause, auto-reconnect, subscribe, write queue
  Services/                     HealthKit export, local notifications, complication updates
  Views/                        home list, one detail page per metric, pairing, settings, diagnostics
SmartRingWatcher Widget/        WidgetKit complication and Smart Stack widget
Shared/                         the summary file shared by the app and the widget (App Group)
Tests/RingProtocolTests/        protocol tests (vectors cross-checked against the vendor SDK)
Tests/AppCoreTests/             store, sync-engine, schedule and settings tests (fake ring, manual clock)
docs/PROTOCOL.md                protocol reference with sources
```

## Tests

The protocol layer, the store and the sync engine are plain Foundation code, so they can be tested on a
Mac without a watch or ring:

```sh
swift test
```

Expected byte values in the protocol tests were produced by running the vendor's own SDK code on the JVM.
This covers the CRC, command framing, and every history record type. The engine tests drive the command
queue, timeouts, retries and the history schedule with a fake ring and a manual clock. CI
(`.github/workflows/ci.yml`) runs the tests and builds the app for the watchOS Simulator.

## Adding files

The project uses Xcode 16 buildable folders, so new files in the app, widget, `Shared/` or `RingProtocol/`
folders are picked up automatically. Files under `SmartRingWatcher Watch App/Core/` are also compiled by
`swift test`, so keep them free of SwiftUI, CoreBluetooth and other watch-only frameworks.

## Notes and limitations

* The protocol comes from the vendor SDK and community reverse engineering. Firmware differs between ring
  models, so a ring may not support every query. Unsupported ones are skipped automatically; see
  Settings → Diagnostics.
* Cuffless blood pressure, blood chemistry and the sleep score are **estimates**, not medical measurements.
  The FDA advises against relying on any watch or ring that claims to measure blood glucose without piercing
  the skin, which is why blood chemistry is hidden by default.
  Smarthealth's own sleep score is computed in its cloud service, so this app shows a transparent estimate
  (duration, deep %, REM % and efficiency).
* The project has a watch-only app target plus its widget extension, which is enough to run on your own
  watch from Xcode. App Store or TestFlight distribution of a watch-only app also needs Xcode's watch-app
  container target. A privacy manifest (`PrivacyInfo.xcprivacy`) is included.

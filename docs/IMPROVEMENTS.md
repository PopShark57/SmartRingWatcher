# SmartRingWatcher: review and suggested improvements

This is a static review of the watchOS app, the `RingProtocol` layer, the tests and the project tooling, as of
commit `481735c`. Nothing was run on a watch or a ring. Line numbers refer to that commit. Paths such as
`BLE/RingSyncEngine.swift` are under `SmartRingWatcher Watch App/`, and `RingProtocol/…` is at the repository
root. Platform and medical claims were checked against the sources listed at the end.

**Priority:** P1 = fix soon (user-visible bug or large impact) · P2 = worthwhile · P3 = polish.
**Effort:** S = under an hour · M = about half a day · L = several days.

## Overall

The codebase is in good shape:

- The protocol layer is pure and Bluetooth-free, and its test vectors were cross-checked against the vendor SDK.
- Edge cases are handled carefully: stale fragments, error replies, plausibility filters and schema migration.
- The command set is conservative (read-mostly, never deletes history).
- The estimate disclaimers are honest.

Most suggestions below fall into four themes:

1. A few behaviour bugs around **data freshness and connection handling**.
2. **Background operation**, which depends on a complication the app doesn't ship.
3. **Battery cost**, mostly from re-downloading the full ring history every few minutes.
4. **watchOS 10-era UI polish**.

## Top items at a glance

| # | Item | Kind | Priority | Effort |
|---|---|---|---|---|
| [F1](#f1) | Polled values are stamped "just now" even when they are hours old | Bug | P1 | S |
| [F2](#f2) | "Disconnect" is undone on the next wrist raise | Bug | P1 | S |
| [F3](#f3) | Demo mode deletes the real cache and still holds the ring connection | Bug | P1 | S |
| [F9](#f9) | Every history sync re-downloads the ring's whole history (default: every 5 min) | Battery | P1 | M |
| [F14](#f14) / [F16](#f16) | Add a complication / Smart Stack widget (background refresh depends on it) | Feature | P1 | M |
| [S1](#s1) | Blood-glucose tile vs. the FDA warning on non-invasive glucose wearables | Safety | P1 | S |
| [F15](#f15) | Write ring data to HealthKit | Feature | P2 | L |
| [S2](#s2) | HRV computed from one or two RR intervals | Data quality | P2 | S |
| [P1](#p1) | Move to `@Observable` and cache derived stats to cut re-renders | Performance | P2 | M |
| [C7](#c7) | watchOS 10 look: container backgrounds, Dynamic Type, haptics, crown-scrubbable charts | Cosmetic | P2 | M |

---

# Part 1: Functional

## 1.1 Bugs and correctness

### <a id="f1"></a>F1. Polled live values are shown as "just now" even when they are hours old (P1, S)

*Where:* `BLE/RingSyncEngine.swift:302-304`, `Store/HealthDataStore.swift:81-95`, `RingProtocol/YCParsers.swift` (`allRealData`)

Each `getAllRealData` poll (every 10 s by default) returns the ring's *last* BP, SpO₂, temperature and
respiration values, stamped `updatedAt: now`. `applyLive` then sets `liveDates[field] = now` for every field in
the patch, and `latest(…)` prefers the live value whenever its date is newer than history. As a result, the blood
pressure tile says "just now" for a reading taken this morning, and the timestamp resets on every poll. The engine
already knows this (see the comment on `recordStreamedSamples`: polled snapshots "may repeat an old measurement"),
but that knowledge never reaches the store.

*Fix:* pass `pushed` through to the store. A pushed value, or a value that changed, means a new measurement; an
unchanged polled value keeps its previous date.

```swift
func applyLive(_ patch: LiveSnapshot, pushed: Bool) {
    let at = patch.updatedAt ?? Date()
    var dates = liveDates
    for field in LiveField.allCases where field.isPresent(in: patch) {
        // A poll repeats the ring's last value; only a push or a change is a new reading.
        if pushed || dates[field] == nil || field.differs(patch, from: live) {
            dates[field] = at
        }
    }
    …
}
```

(`differs(_:from:)` would be a small helper next to `isPresent(in:)`.) This also stops the store from publishing
and re-saving on every poll (see [P1](#p1) and [P3](#p3)).

### <a id="f2"></a>F2. "Disconnect" is silently undone when the app becomes active again (P1, S)

*Where:* `BLE/RingBluetoothManager.swift:146-174`; `BLE/RingSyncEngine.swift:60-71, 83-92, 97-109, 144-163`

`disconnect(forget: false)` sets `autoConnect = false`. However, `setForeground(true)`, `refreshNow()`,
`settingsChanged()` and `performBackgroundSync` all call `connectSavedRing()`, which sets `autoConnect = true`
again. When the wrist goes down the scene becomes `.inactive`, and when it comes back up it is `.active`, so the
ring reconnects within seconds. That defeats the main reason to press Disconnect, which is to let Smarthealth on
the phone connect (as the pairing footer itself suggests).

*Fix:* persist a "paused" flag next to the saved ring ID. Disconnect sets it, and only an explicit **Reconnect**
clears it. `connectSavedRing()` does nothing while paused, and the header shows "Paused · tap to reconnect".

### <a id="f3"></a>F3. Demo mode erases the real cache and keeps the real ring connected (P1, S)

*Where:* `BLE/RingSyncEngine.swift:377-399`, `Store/HealthDataStore.swift:102-127`,
`BLE/RingBluetoothManager.swift:264-267`

- Turning demo mode **on** calls `replaceAll` → `eraseAll()`, which deletes `health-store.json`. Turning it **off**
  erases the demo data. Up to 14 days of cached history is lost, which may be more than the ring still holds. The
  footer does say "Replaces cached data", but a toggle on a watch is easy to hit by accident.
- The transport doesn't know about demo mode, so it still auto-connects to the saved ring.
  `transportDidBecomeReady` then returns early, which leaves the ring connected but unused and blocks the phone
  app.

*Fix:* give demo mode its own store, e.g. `HealthDataStore(fileName: "demo-store.json")`, and swap the
environment object. Pause the transport (see [F2](#f2)) while demo mode is on.

### <a id="f4"></a>F4. The protocol time zone is frozen at launch, and the ring clock is only set on connect (P2, S)

*Where:* `BLE/RingSyncEngine.swift:30` (`YCProtocolSession()` captures `TimeZone.current` once),
`RingProtocol/YCProtocolSession.swift:46-53`, and `syncClock()`, which is sent only from `transportDidBecomeReady`

Ring timestamps are in local wall-clock time. After travel or a DST change, with the app still in memory and the
ring still connected, two things go wrong:

- History is decoded with the old offset. The same record then gets a different `Date` than before, so `merge`
  keeps both copies.
- The ring keeps the old time until the next reconnect.

*Fix:* observe `.NSSystemTimeZoneDidChange` and `.NSSystemClockDidChange`. On either, set
`session.timeZone = .current` and enqueue `YCCommand.syncClock()`. Also re-sync the clock once a day while
connected.

### <a id="f5"></a>F5. Background refresh records a full history sync after fetching only HR and steps (P3, S)

*Where:* `BLE/RingSyncEngine.swift:422-442`, `265-273`

When the app wakes for Background App Refresh and connects:

1. `syncHistory()` sets `isSyncingHistory = true`.
2. The queue is filtered down to heart and sport history.
3. When the queue drains, `lastHistorySync = Date()`.

If the user then opens the app within 60 s, `setForeground` skips the full history sync because it looks fresh.

*Fix:* filter before calling `syncHistory()`, or track a last-sync date per type (which [F9](#f9) needs anyway).

### <a id="f6"></a>F6. A measurement result without a kind is attributed to heart rate (P3, S)

*Where:* `BLE/RingSyncEngine.swift:328`: `kind ?? activeMeasurement ?? .heartRate`

A stray result with an unknown kind, arriving while no measurement is active, shows up as a heart-rate outcome and
triggers a heart-rate history fetch. Ignore it when both values are `nil`.

### <a id="f7"></a>F7. "Today" values don't roll over at midnight when no data arrives (P3, S)

*Where:* `Store/HealthDataStore.swift:145-231`

`stepsToday`, `hourlyStepsToday` and similar values are computed at render time, but views only re-render when the
store publishes. If the ring is out of range overnight, yesterday's steps stay on screen until the next change.

*Fix:* observe `.NSCalendarDayChanged` to force a refresh, or wrap the activity views in
`TimelineView(.explicit([nextMidnight]))`.

### <a id="f8"></a>F8. A history type is disabled after three failures of any kind (P3, S)

*Where:* `BLE/RingSyncEngine.swift:193, 208, 247, 313`

`failureCounts` counts a timeout the same way as an "unsupported" error reply. After three failures the type is
skipped until the next reconnect, and the ring can stay connected for days. So one bad patch of radio can disable
heart-rate history for days.

*Fix:* treat an error reply (`0xFB`/`0xFC`) as "unsupported" and disable the type. Treat a timeout as transient
and retry with exponential backoff. Show the status of each type in Diagnostics.

## 1.2 Bluetooth and sync

### <a id="f9"></a>F9. Every history sync re-downloads the ring's entire history (P1, M)

*Where:* `BLE/RingSyncEngine.swift:205-213`, `Store/AppSettings.swift:16`

The app deliberately never sends `Health_Delete*`, which is the right call for coexisting with Smarthealth. The
consequence is that each `syncHistory()` transfers **every stored record for all nine types**: every 5 minutes by
default, and as often as every minute. That is the biggest radio and battery cost for both the watch and the ring.
It also keeps the command queue busy, so live polls lag behind.

- **Schedule each type on its own interval:**
  - Heart, sport and "all": every 15 min.
  - Sleep: once in the morning (for example, the first sync after 06:00 when the newest session is more than 12 h
    old).
  - BP, SpO₂, temperature and body data: every 30–60 min.
  - Blood chemistry: only after a measurement.
- **Change the options:** drop the 1-minute setting and default to 15 min. Update the README to match.
- **Make the cost visible:** log the size of each transfer in Diagnostics. The history header carries
  `count`/`bytes`.

### <a id="f10"></a>F10. Scanning floods SwiftUI with updates (P2, S)

*Where:* `BLE/RingBluetoothManager.swift:115, 281-299`

The app scans with `AllowDuplicatesKey: true` and no service filter. Every advertisement mutates and re-sorts the
`@Published discovered` array, so the pairing list re-renders many times a second and rows jump around as RSSI
fluctuates.

*Fix:*

- Keep the raw results in a private dictionary and publish a sorted snapshot at most once a second.
- Sort by RSSI bucket, or by a moving average, instead of the raw value.
- Show likely rings first and put the others behind **Show all devices**.

### <a id="f11"></a>F11. A connection attempt can hang with no feedback (P2, S)

CoreBluetooth connections never time out, as the code comments note. For auto-reconnect that is correct. From the
pairing screen, though, "Connecting to X…" with a pulsing icon can last forever, and there is no Cancel.

- After about 15 s, show "Ring not responding: is it charged and nearby? Is Smarthealth connected on your phone?"
  with a **Cancel** button.
- After about 30 s of `.reconnecting`, stop the pulse and show a static "Waiting for ring".

### <a id="f12"></a>F12. Bluetooth errors are swallowed (P3, S)

`didFailToConnect`, `didDiscoverServices`, `didDiscoverCharacteristicsFor`, `didUpdateNotificationStateFor` and
`didWriteValueFor` all ignore their `error` argument. Send those errors to the Diagnostics log and `os.Logger`.
That is exactly what you need when someone reports that their ring model doesn't work.

### <a id="f13"></a>F13. Standard-GATT rings: battery never refreshes, and "Sync now" does nothing (P3, S)

- Battery `2A19` is read once, at discovery. Re-read it every few minutes when there is no YC channel.
- **Sync now** and **Measure now** have no effect without `hasProtocolChannel`. Hide them, or explain why they
  are unavailable.

### <a id="f14"></a>F14. Background operation depends on a complication the app doesn't have (P1, M)

The README promises about 4 background refreshes an hour. Apple grants up to four an hour **when the app has a
complication on the active watch face**. Apps without one are deprioritized and may get fewer.

The declared `bluetooth-central` mode (watchOS 9+, Series 6+) lets Core Bluetooth keep the connection and wake the
app when a characteristic changes. Those wake-ups are capped, though: WWDC22 describes 5 per rolling 24 h, reset
when the user interacts with the app. Background App Refresh continues regardless of that cap **if the complication
is on the active face**.

*Fix:* ship a complication ([F16](#f16)) and update the README to describe the actual behaviour. Turning streaming
off when the app goes inactive (`setForeground(false)`) is already correct; keep it that way so pushed frames don't
use up the wake budget.

## 1.3 New features

### <a id="f15"></a>F15. Write ring data to HealthKit (P2, L)

This is the most valuable feature to add. Ring data would appear in Health and the Fitness trends, be available to
other apps, and be backed up with the user's health data.

| Ring data | HealthKit |
|---|---|
| Heart rate | `heartRate` |
| Body-data **SDNN** | `heartRateVariabilitySDNN` (HealthKit's HRV type is SDNN, so don't store RMSSD in it) |
| SpO₂, respiration | `oxygenSaturation`, `respiratoryRate` |
| Blood pressure | `bloodPressure` correlation (systolic + diastolic) |
| Sport intervals | `stepCount`, `distanceWalkingRunning`, `activeEnergyBurned` |
| Sleep stages | `sleepAnalysis`: deep → `.asleepDeep`, light → `.asleepCore`, REM → `.asleepREM`, awake → `.awake`, session → `.inBed` |

Points to watch:

- Set `HKMetadataKeySyncIdentifier` and `HKMetadataKeySyncVersion` so that re-downloaded history ([F9](#f9)) doesn't
  create duplicates.
- Attach an `HKDevice` with the ring's name and firmware.
- Tell users that ring steps overlap with the watch's own steps. Health de-duplicates them by source priority.
- Skip temperature (finger skin temperature is not body temperature) and blood chemistry (see [S1](#s1)).
- Add the HealthKit capability and `NSHealthUpdateUsageDescription`.

### <a id="f16"></a>F16. Complication and Smart Stack widget (P1, M)

Build it with WidgetKit; ClockKit has been deprecated since watchOS 9. On watchOS 10, the `accessoryRectangular`
family also serves as the Smart Stack widget.

- **Content:** latest HR with its age, a steps gauge, and ring battery.
- **Plumbing:** add an App Group so the app can share a small summary file with the widget. After each sync, call
  `WidgetCenter.shared.reloadTimelines(ofKind:)`, which is budgeted by the system.
- **Benefit:** the data becomes glanceable, and the app gets background-refresh priority ([F14](#f14)).

### <a id="f17"></a>F17. Local notifications (P3, M)

Make these opt-in:

- Ring battery low (15 % or less, once per charge).
- Ring not seen for more than 24 h.
- A measurement finished while the app was in the background.

### <a id="f18"></a>F18. Use the wear state (P3, S)

`isWorn` is parsed from `0x0613` but never used. Use it to:

- Show "Not worn" in the header.
- Dim the live tiles.
- Disable **Measure now**, with a hint to put the ring on.

### <a id="f19"></a>F19. Configurable step goal and units (P3, S)

- `Views/Metrics/ActivityView.swift:6` hard-codes a goal of 10,000 steps. Add a goal picker in Settings.
- If blood chemistry stays, offer mg/dL based on the locale: glucose ×18, cholesterol ×38.67, triglycerides ×88.57.

### <a id="f20"></a>F20. Measure uric acid and ketone too (P3, S)

`Views/Metrics/VitalsViews.swift:235` only offers a glucose measurement. If the blood-chemistry features stay
([S1](#s1)), let the user pick glucose, uric acid or ketone.

### <a id="f21"></a>F21. Richer, exportable Diagnostics (P3, S)

- Add a `ShareLink` for the log.
- Show the CRC error count. `YCProtocolSession.crcErrors` is tracked but never displayed.
- Show failure counts per type, the protocol, the firmware, and the write MTU (`maximumWriteValueLength`).
- Add an optional raw-frame hex view.
- Give log entries stable IDs. Today they are keyed by array offset (`DeviceView.swift:169`), and offsets shift
  when the log is trimmed.

## 1.4 Health data quality and safety

### <a id="s1"></a>S1. Blood-glucose and blood-chemistry display (P1, S)

The FDA's 21 Feb 2024 safety communication advises people **not** to use smartwatches or smart rings that claim to
measure blood glucose without piercing the skin. No such device is authorized, and a wrong value can lead to a
dangerous dosing error. The home tile does label glucose "(estimate)" and the page has a disclaimer, but glucose
is still a first-class tile with a **Measure now** button.

- Hide blood chemistry by default behind a Settings toggle ("Show experimental blood-chemistry estimates"), with
  an explicit warning.
- Never classify or colour-code these values, and don't write them to HealthKit.
- If App Store distribution is ever planned: guideline 1.4.1 requires apps to disclose the data and methodology
  behind accuracy claims for health measurements, and rejects apps whose accuracy can't be validated. Glucose and
  cuffless BP would draw extra scrutiny.

### <a id="s2"></a>S2. HRV from a single standard-GATT notification isn't meaningful (P2, S)

*Where:* `BLE/RingSyncEngine.swift:470`

RMSSD is computed from the RR intervals in *one* `0x2A37` notification. That is typically one or two intervals,
so at most one successive difference. Published validation work treats about 10 s as the shortest usable RMSSD
recording, and 60 s as the more reliable "ultra-short" window.

*Fix:* buffer RR intervals over a rolling 60 s window and reject artifacts: intervals outside 0.3–2.0 s, or a jump
of more than 20 % from the previous interval. Report RMSSD only once about 30 or more beats are available.

### <a id="s3"></a>S3. The "HRV" series mixes different metrics (P2, S)

`store.hrv` receives four kinds of value:

- The vendor "HRV" byte in `0x0509` (definition unknown).
- Body-data RMSSD, or SDNN when RMSSD is missing.
- RMSSD computed from GATT RR intervals.
- Byte 3 of `0x0603`.

RMSSD and SDNN are not interchangeable, so the 24 h chart and the min/avg/max can jump depending on the source.

*Fix:* store the kind with each sample (`.rmssd`, `.sdnn`, `.vendor`), chart one kind, and label it.

### <a id="s4"></a>S4. Softer, context-aware classifications (P3, S)

- **Heart rate:** `HeartRateView.zone(for:)` calls anything below 60 BPM "Low" and 100–130 "Elevated", without
  knowing the context (athletes, activity). Classify only resting estimates, or use neutral wording.
- **Resting HR:** the 10th-percentile estimate includes sleeping HR, which is usually lower than resting HR while
  awake. Compute it from awake hours with no steps, or rename it "Lowest HR (24 h)".
- **Blood pressure:** the thresholds match ACC/AHA (2017, unchanged in 2025). The 2025 guideline calls >180/120
  without organ damage "severe hypertension". "Hypertensive crisis" is alarming wording for a cuffless estimate;
  suggest "Very high: re-measure with a cuff".
- The SpO₂ (≥95 % normal) and respiration (12–20/min) ranges match standard references and can stay as they are.

## 1.5 Performance and battery

### <a id="p1"></a>P1. `ObservableObject` fan-out (P2, M)

Every `@Published` change in `HealthDataStore` invalidates every view that observes the store. That includes each
live poll (every 10 s, or every 2 s while streaming). Derived values are then recomputed on each render:

- `restingHeartRate` sorts 24 h of heart rate.
- `HeartRateView.day` runs `last24h(...)` four times per body evaluation.
- `apply()` reassigns all ten arrays, which publishes ten times.

*Fix:*

- Migrate the four model classes to `@Observable`. The watchOS 10 target already allows it, and views then update
  only when a property they read changes.
- Cache derived summaries (resting HR, 24 h stats, hourly steps) and recompute them once per data change.
- Only assign the arrays that actually changed.

### <a id="p2"></a>P2. `RelativeTimeLabel` re-renders every tile every 5 s (P3, S)

*Where:* `Views/Components/Components.swift:94-115`

A 5-second `TimelineView` wraps `Text(date, style: .relative)`, which already updates itself and shows seconds
("2 min, 14 sec"). Per-minute granularity is enough, and localized:

```swift
TimelineView(.everyMinute) { context in
    let age = context.date.timeIntervalSince(date)
    if age < 60 {
        Text("Just now")
    } else if age < 20 * 3600 {
        Text(date, format: .relative(presentation: .named))   // "5 minutes ago", localized
    } else {
        Text(date, format: .dateTime.weekday(.abbreviated).hour().minute())
    }
}
```

### <a id="p3"></a>P3. JSON persistence on the main thread (P3, M)

*Where:* `Store/HealthDataStore.swift:296-310, 312-340`

`save()` encodes 14 days of every series into one JSON blob on the main thread, 2 s after *any* change. Because of
[F1](#f1), that currently means after every live poll.

- Snapshot the value types and encode on a background queue.
- Don't re-save the whole history for live-only changes.
- Longer term, consider SwiftData (watchOS 10+) or one file per series.

`load()` uses `try?`, so a decoding failure after a model change silently drops the cache, and the next save
overwrites the file. Log the error, and keep a `.bak` copy before overwriting.

### <a id="p4"></a>P4. Small items (P3, S)

- `addLog` creates a `DateFormatter` on every call (`BLE/RingSyncEngine.swift:369`). Use a static formatter or
  `Date.FormatStyle`.
- `peripheralsByID` grows without bound across scans.

## 1.6 Architecture, code quality and tooling

### <a id="a1"></a>A1. Main-actor isolation and Swift 6 (P2, M)

The project uses `SWIFT_VERSION = 5.0`. The four model classes are main-thread-only by convention (Core Bluetooth
queue `nil`, timers on the main run loop), but nothing says so. Mark them `@MainActor`, enable complete strict
concurrency checking, and then move to Swift 6 language mode.

### <a id="a2"></a>A2. Make the engine and store testable (P2, M)

The protocol tests are excellent, but `HealthDataStore` and `RingSyncEngine` have none.

- Extract a `RingTransport` protocol (state, `hasProtocolChannel`, `write`, `connectSavedRing`). The queue,
  timeout, background and pause logic can then be tested with a fake transport.
- Inject the clock and the timers.
- Add tests for:
  - `merge` and retention.
  - `stepsToday`, `lastNightSleep` and `restingHeartRate`.
  - Schema migration.
  - Regression tests for F1–F5.

### <a id="a3"></a>A3. Settings propagation (P3, S)

The engine only learns about settings changes through `.onChange` in `SettingsView`
(`Views/DeviceView.swift:148-151`). A setting changed anywhere else, such as from a future onboarding flow, won't
reach it. Have the engine observe `AppSettings` itself.

### <a id="a4"></a>A4. Logging (P3, S)

Replace `print` (`App/SmartRingWatcherApp.swift:74`, `Store/HealthDataStore.swift`) with
`os.Logger(subsystem:category:)`, using `ble`, `sync` and `store` categories. Keep the in-app ring buffer for
Diagnostics.

### <a id="a5"></a>A5. Continuous integration (P2, S)

There is no `.github/workflows`. Add a macOS job that runs `swift test` and builds the watch target for the watchOS
Simulator with `xcodebuild`. SwiftLint or SwiftFormat is optional.

### <a id="a6"></a>A6. Project generation (P3, M)

`tools/generate_xcodeproj.py` exists because the project file lists every source file. Xcode 16 **buildable
folders** (`PBXFileSystemSynchronizedRootGroup`) record only the folder, which removes the need for the script and
most project-file churn. The trade-off is that the project no longer opens in Xcode 15. XcodeGen or Tuist are
alternatives.

### <a id="a7"></a>A7. Distribution readiness (P3, M)

- Add `PrivacyInfo.xcprivacy`, declaring `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1`. It has
  been required for App Store uploads since 1 May 2024.
- Replace the `com.example` bundle identifier and set version and build numbers.
- Add the watch-only container target (the README already mentions it).
- Remove `INFOPLIST_KEY_UISupportedInterfaceOrientations`, which looks like an iOS template leftover.

---

# Part 2: Cosmetic and UX

## 2.1 Home screen

### <a id="c1"></a>C1. First-run experience (P2, S)

With no ring and no data, the home screen is a list of `--` tiles. Show an onboarding card instead: **Pair your
ring** (primary), **Try demo data** (secondary), and the "one connection at a time" tip. Hide tiles that have never
had data, the way the blood-chemistry tile already works, and add **Edit tiles** in Settings to reorder or hide
them.

### <a id="c2"></a>C2. Show staleness (P2, S)

- Dim a tile's value (`.secondary`) once it is more than about 6 h old.
- Show a small badge once it is more than a day old.

This goes together with [F1](#f1): once timestamps are honest, the UI should show that a value is old.

### <a id="c3"></a>C3. Grouping and a summary row (P3, S)

The current order puts HRV with heart rate but Stress with the vitals. Suggested sections:

- **Today:** Activity, Sleep.
- **Heart:** HR, HRV, Stress.
- **Vitals:** BP, SpO₂, Temperature, Respiration.

Alternatively, add a hero row at the top with a steps gauge (`Gauge` in `.accessoryCircularCapacity` style), the
current HR and last night's sleep.

### <a id="c4"></a>C4. Make tiles feel alive (P2, S)

- `.contentTransition(.numericText())` in `MetricTile` and `HeroValue` only animates inside an animation
  transaction, and the values change outside one. Add `.animation(.snappy, value: value)`.
- Add `.symbolEffect(.bounce, value: date)` on the metric icon when a fresh value arrives, and `.pulse` on the
  heart while streaming.
- Give each row a very subtle tint of its metric colour.

### <a id="c5"></a>C5. Pull to refresh (P3, S)

The engine's comment mentions pull-to-refresh, but the list doesn't implement it. Add
`.refreshable { engine.refreshNow() }` (available since watchOS 8) and keep the button for discoverability.

### <a id="c6"></a>C6. Header details (P3, S)

- Use the `battery.100percent.bolt` family of symbols for charging, instead of the "⚡︎" text glyph
  (`Views/DeviceView.swift:25`). Show the charging state in the home header too.
- Show the "Not worn" ([F18](#f18)) and "Paused" ([F2](#f2)) states.

## 2.2 Detail pages

### <a id="c7"></a>C7. watchOS 10 look (P2, M)

- `.containerBackground(style.color.gradient, for: .navigation)` on each detail page gives every metric its own
  tinted full-screen background, which matches the system apps.
- Consider a vertically paged `TabView` (`.tabViewStyle(.verticalPage)`) for longer pages, for example: hero value
  and Measure → chart → stats.
- `HeroValue` uses a fixed 40 pt font (`Views/Components/Components.swift:132`), so it ignores the user's text
  size. Use `.system(.largeTitle, design: .rounded)` or `@ScaledMetric`.
- The activity ring is a fixed 120×120 frame (`ActivityView.swift:28`). Scale it with `@ScaledMetric` and check it
  at the largest text sizes.

### <a id="c8"></a>C8. Charts (P2, M)

- **Crown scrubbing:** `chartXSelection(value:)` (watchOS 10) plus a `RuleMark` annotation can show the value at a
  chosen time. Drive the selection with `.focusable().digitalCrownRotation(…)`.
- **Context marks:**
  - An `AreaMark` gradient under the HR line.
  - A dashed `RuleMark` at the 24 h average.
  - Shaded `RectangleMark` bands for normal ranges: SpO₂ 95–100, respiration 12–20, BP below 120/80, and a 7–9 h
    band on the sleep bars.
- **`BloodPressureChart`:** the Y domain is fixed at `50...170` (`Charts.swift:63`), which clips plausible readings
  up to 250. Derive the domain from the data, with a minimum span.
- **`TrendChart` axis:** the X axis is always labelled by hour (`Charts.swift:34`). That is wrong for the
  blood-chemistry chart, which spans up to 14 days. Choose the format from the span of the data.
- **`SleepStagesChart`:** it always reserves a "Nap" row. Include only the stages that occur.
- **Weekly bars:** weekly sleep omits nights without data, while the 7-day steps chart fills them with zeros. Make
  them consistent.
- **Units:** add a small unit caption (BPM, ms, %), because the axes carry no units.

### <a id="c9"></a>C9. Measurement flow (P2, S)

The button currently just stops spinning.

- Show a circular countdown. Rings take about 30–60 s, and the timeout is 90 s.
- Play `.sensoryFeedback(.success, trigger:)` or `.error` (watchOS 10) when the measurement ends. Users usually
  look away while measuring.
- Show the new value inline with a checkmark.
- Expand the hint to "Keep still, ring snug".

### <a id="c10"></a>C10. Activity goal (P3, S)

When the step goal is reached, play a haptic and change the ring's colour or style. Show the steps remaining under
the count.

## 2.3 Pairing screen

### <a id="c11"></a>C11. Friendlier scan list (P3, S)

- Replace "-67 dBm" with signal bars: `Image(systemName: "cellularbars", variableValue: level)`.
- Split the list into **Likely rings** and **Other devices** (collapsed).
- For the saved ring, show when it was last connected and its last battery level.

## 2.4 Text, formatting and localization

### <a id="c12"></a>C12. Locale-aware numbers and temperature (P2, S)

`String(format: "%.1f")` always uses a dot as the decimal separator. It appears in `Components.swift:276-279`,
`AppSettings.formatTemperature` and `VitalsViews.swift:184`. Use `value.formatted(.number.precision(.fractionLength(1)))`
instead.

For temperature, the Measurement API picks °C or °F from the locale:

```swift
Measurement(value: celsius, unit: UnitTemperature.celsius)
    .formatted(.measurement(width: .abbreviated, usage: .person,
                            numberFormatStyle: .number.precision(.fractionLength(1))))
```

The Fahrenheit toggle can then become an override: Automatic, °C or °F.

### <a id="c13"></a>C13. Localization (P3, M)

All strings are English literals. Labels passed as `String` won't be picked up by a String Catalog: `DetailRow`,
`MetricStyle.title` and `displayName`. Switch those to `LocalizedStringKey` or `LocalizedStringResource`, add
`Localizable.xcstrings` (the project already sets `LOCALIZATION_PREFERS_STRING_CATALOGS = YES`), and use
pluralization for counts such as "Times awake". Replace `"… ago"` interpolations with the relative format style
([P2](#p2)).

## 2.5 Always On and accessibility

### <a id="c14"></a>C14. Always On (P3, S)

Read `@Environment(\.isLuminanceReduced)`. When it is true:

- Hide second-level times and pulsing symbols.
- Dim the bright fills (the activity ring stroke, gradients).
- Rely on per-minute timelines; apps without an active session update at most once a minute.

### <a id="c15"></a>C15. VoiceOver for charts (P3, S)

- Add an `accessibilityChartDescriptor` (Audio Graphs) to the charts, or at least a summary label such as "Heart
  rate, last 24 hours, 52 to 118 BPM, average 71".
- Label the sleep-stage and BP bars.
- `MetricTile`'s `.accessibilityElement(children: .combine)` is already good. Adding a hint ("Shows history")
  would complete it.

### <a id="c16"></a>C16. Icon and tint (P3, S)

The app icon is strong: the thick ring and white pulse read well at small sizes. Two small suggestions:

- The accent colour (`#FA456B`) is pinker than the icon's orange-to-magenta gradient. Take the accent from the
  icon's mid-tone so the tint and the icon match.
- Draw a single-colour glyph of the pulse inside the ring (a custom SF Symbol) for the complication ([F16](#f16)).

---

## Suggested order of work

1. **Quick fixes (about a day):** F1, F2, F3, F6, S1, C4 (animation), C5, C12.
2. **Background and battery (a few days):** F9, F16 + F14 (complication, App Group, README), P1, P2, P3.
3. **Features:** F15 (HealthKit), F18, C9, F17.
4. **Polish and hygiene:** C7, C8, C13, A1, A2, A5, A7.

## Sources

- Background refresh budget with and without a complication:
  [WWDC20: Keep your complications up to date](https://developer.apple.com/videos/play/wwdc2020/10049/),
  [Apple Developer Forums: Maximise background update on watchOS](https://developer.apple.com/forums/thread/788713)
- Background Bluetooth on watchOS (`bluetooth-central`, wake-up limits, Series 6+):
  [WWDC22: Get timely alerts from Bluetooth devices on watchOS](https://developer.apple.com/videos/play/wwdc2022/10135/)
- WidgetKit complications and Smart Stack:
  [WWDC22: Complications and widgets: Reloaded](https://developer.apple.com/videos/play/wwdc2022/10050/),
  [WWDC23: Build widgets for the Smart Stack on Apple Watch](https://developer.apple.com/videos/play/wwdc2023/10029/)
- FDA warning on non-invasive glucose wearables (21 Feb 2024):
  [CNN](https://www.cnn.com/2024/02/21/health/fda-warning-smartwatches-blood-glucose/),
  [Healio](https://www.healio.com/news/endocrinology/20240222/fda-avoid-using-smartwatches-smart-rings-to-measure-blood-glucose)
- App Review Guideline 1.4.1: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- 2025 ACC/AHA blood-pressure categories:
  [AHA: 2025 High Blood Pressure Guideline, top things to know](https://professional.heart.org/en/science-news/2025-high-blood-pressure-guideline/top-things-to-know),
  [Guideline Central summary](https://www.guidelinecentral.com/guideline/6962/)
- Normal SpO₂ and respiration ranges:
  [Wikipedia: Oxygen saturation](https://en.wikipedia.org/wiki/Oxygen_saturation_(medicine)),
  [Wikipedia: Respiratory rate](https://en.wikipedia.org/wiki/Respiratory_rate)
- Minimum recording length for RMSSD:
  [Munoz et al., Validity of (ultra-)short recordings for HRV, PLOS One 2015](https://journals.plos.org/plosone/article?id=10.1371%2Fjournal.pone.0138921),
  [Esco & Flatt, ultra-short-term HRV in athletes](https://www.researchgate.net/publication/263652960_Ultra-Short-Term_Heart_Rate_Variability_Indexes_at_Rest_and_Post-Exercise_in_Athletes_Evaluating_the_Agreement_with_Accepted_Recommendations)
- HealthKit types:
  [HKCategoryValueSleepAnalysis](https://developer.apple.com/documentation/healthkit/hkcategoryvaluesleepanalysis),
  [heartRateVariabilitySDNN](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn)
- Privacy manifest, UserDefaults reason `CA92.1`:
  [TN3183](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest)
- Xcode 16 buildable folders:
  [How synchronized groups work at the .pbxproj level](https://pepicrft.me/blog/how-synchronized-groups-work-at-the-pbxproj-level/),
  [Xcode 16 buildable folders and Xcode 15 compatibility](https://blog.supereasyapps.com/xcode-16-buildable-folders-break-xcode-15-backwards-compatibility/)
- SwiftUI APIs:
  [`@Observable` (watchOS 10)](https://www.swiftanytime.com/blog/observable-macro-in-swiftui),
  [`sensoryFeedback` (watchOS 10)](https://useyourloaf.com/blog/swiftui-sensory-feedback/),
  [`chartXSelection`](https://developer.apple.com/documentation/swiftui/view/chartxselection(value:)),
  [`refreshable` (watchOS 8)](https://www.hackingwithswift.com/quick-start/swiftui/how-to-enable-pull-to-refresh),
  [`containerBackground`](https://swift.mackarous.com/posts/2024/08/modifiers-container-background/),
  [`contentTransition(.numericText())` needs an animation](https://sarunw.com/posts/animating-number-changes-in-swiftui/),
  [Always On and `TimelineView`](https://developer.apple.com/videos/play/wwdc2021/10002/),
  [Measurement formatting usages](https://goshdarnformatstyle.com/measurement-style/)

# Smarthealth ring protocol ("YC" protocol)

Smarthealth ([App Store id1450500729](https://apps.apple.com/us/app/smarthealth/id1450500729)) is published by
Shenzhen Yucheng Innovation Technology. Rings sold with it speak Yucheng's BLE protocol, which this app
implements in `RingProtocol/`. Everything below comes from the vendor's own Android SDK
(`ycbtsdk-release.aar`, classes `YCBTClient`, `YCBTClientImpl`, `DataUnpack`, `Constants`, `ByteUtil`,
`TimeUtil`, `BleHelper`). A copy of the SDK is in the public reverse-engineering repo
[yucheng-watch-s26](https://github.com/yucheng-watch-s26/yucheng-watch-s26.github.io) (`assets.zip`).
The byte layouts were confirmed by running the SDK's `DataUnpack.unpackHealthData` on the JVM against the
test vectors in `Tests/RingProtocolTests`.

## GATT

| Service | Characteristic | Use |
|---|---|---|
| `BE940000-7333-BE46-B7AE-689E71722BD5` (YC) | `BE940001-…` write + indicate | commands in, replies out |
| | `BE940003-…` indicate | replies / uploads out |
| `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` (Nordic UART) | `6E400002` write, `6E400003` notify | same frames, used only if YC is absent |
| `180D` Heart Rate | `2A37` notify | standard live HR (+ RR intervals → HRV) |
| `180F` Battery | `2A19` read/notify | battery % |
| `180A` Device Information | `2A29`, `2A24`, `2A26` | manufacturer, model, firmware |

## Frame format

```
[group][key][len lo][len hi][payload…][crc lo][crc hi]
```

* `len` counts every byte, including the 4-byte header and the CRC.
* CRC-16/CCITT-FALSE (poly `0x1021`, init `0xFFFF`) over everything before the CRC.
  Check value for `"123456789"` is `0x29B1`.
* Frames longer than the ATT MTU arrive split across notifications; `YCFrameAssembler` rejoins them.
* A 1-byte payload `0xFB`…`0xFF` is an error reply (`0xFB` unsupported command, `0xFC` unsupported key).
* Ring-initiated events (group `0x04`) must be acknowledged with the same data type and payload `[0x00]`.

Examples produced by the SDK: `05 04 06 00 E3 4E` (request sleep history),
`02 00 08 00 47 43 6F EC` (device info), `05 80 07 00 00 F3 6A` (history transfer OK).

## Commands the app sends

| Data type | Name (SDK) | Payload | Purpose |
|---|---|---|---|
| `0x0100` | SettingTime | `yearLo yearHi month day hour min sec weekday(Mon=0)` local time | set ring clock |
| `0x0200` | GetDeviceInfo | `47 43` | firmware, battery |
| `0x020C` | GetNowStep | – | today's steps/kcal/distance (fallback) |
| `0x020E` | GetRealTemp | – | temperature (fallback) |
| `0x0211` | GetRealBloodOxygen | `49 53` | SpO2 (fallback) |
| `0x0220` | GetAllRealDataFromDevice | – | live snapshot, polled for auto-refresh |
| `0x0309` | AppControlReal | `enable kind interval_s` | optional live streaming (kind 0 steps, 1 HR) |
| `0x032F` | AppStartMeasurement | `start kind` | on-demand measurement (kinds below) |
| `0x05xx` | Health_History* | – | request stored history (see below) |
| `0x0580` | Health_HistoryBlock | `00` OK / `04` retry | acknowledge a history transfer |

Measurement kinds (shared with event `0x0413`): 0 heart rate, 1 blood pressure, 2 SpO2, 3 respiration,
4 temperature, 5 glucose, 6 uric acid, 7 ketone.

**Not sent on purpose.** `0x0303` is `AppBloodCalibration` (some write-ups call it an SpO2 switch). The
`Health_Delete*` commands (`0x0540`–`0x0552`) are also never sent, so Smarthealth on the phone still
receives the full history.

## Live data

| Data type | Layout |
|---|---|
| `0x0220` reply | HR, SBP, DBP, SpO2, resp, tempInt, tempFrac, steps u24, kcal u16, distance u16, … |
| `0x0600` sport | steps u16, distance u16, kcal u16 |
| `0x0601` heart | bpm |
| `0x0602` SpO2 | % |
| `0x0603` blood | SBP, DBP, HR, [HRV], [SpO2], [tempInt, tempFrac] |
| `0x0607` respiration | breaths/min |
| `0x060A` comprehensive | steps u24, dist u16, kcal u16, HR, SBP, DBP, SpO2, resp, tempInt, tempFrac, wear, battery, PPI u32, … |
| `0x0610` body data | fatigue, HRV, stress, body energy, sympathetic (each int+frac), SDNN u16, VO2max, pNN50, RMSSD u16, LF u16, HF u16, LF/HF×10 |
| `0x040E` measurement result | kind, result (1 ok, 2 fail, 3 cancel) |
| `0x0413` measurement status | kind, state, values… |

Decimals are sent as an integer byte and a fraction byte and rebuilt as the string `"int.frac"`, as the SDK does.

## History transfer

1. App sends the request, e.g. `0x0506` (heart).
2. Ring replies with a header on the same key. If its payload is ≤ 9 bytes there is no data. Otherwise it holds
   `count u16, packets u32, bytes u32`.
3. Ring sends data frames on another key (for example `0x0515`). Their payloads are concatenated.
4. Ring sends `0x0580` with `packets u16, bytes u16, crc u16`. The app checks the CRC of the concatenated data
   and answers `0x0580 [00]`, or `[04]` on a mismatch.

Record timestamps are **local wall-clock seconds since 2000-01-01** (`raw + 946684800 - tzOffset` = Unix time).

| Request | Record | Layout (little-endian) |
|---|---|---|
| `0x0502` sport | 14 B | start u32, end u32, steps u16, distance m u16, kcal u16 |
| `0x0504` sleep | variable | header 20 B: `AF FA`, len u16, start u32, end u32, then `FF FF` + REM s u16 + deep s u16 + light s u16 (new firmware) or deepCount u16, lightCount u16, deep min u16, light min u16 (old firmware); then 8 B stages: type (241 deep, 242 light, 243 REM, 244 awake, 245 nap), start u32, duration s u24 |
| `0x0506` heart | 6 B | time u32, mode, bpm |
| `0x0508` blood | 8 B | time u32, cuff flag, SBP, DBP, HR |
| `0x0509` all | 20 B | time u32, steps u16, HR, SBP, DBP, SpO2, resp, HRV, CVRR, tempInt, tempFrac, fatInt, fatFrac, glucose, 2 reserved |
| `0x051A` SpO2 | 6 B | time u32, type, % |
| `0x051E` temperature | 7 B | time u32, type, int, frac |
| `0x052F` blood chemistry | 44 B | time u32, glucose model/int/frac, uric model/u16, ketone model/int/frac, lipid model, TC, HDL, LDL, TG (int/frac pairs), padding |
| `0x0533` body data | 28 B | time u32 + the `0x0610` layout |

## Corrections to earlier community notes

* Clock sync is the 8-byte calendar payload above, not a 4-byte epoch.
* In the `0x0509` "all" record, byte 11 is HRV and bytes 13–14 are temperature.
* `0x0303` is blood-pressure calibration, as noted above.

## Sources

* Vendor SDK (`ycbtsdk-release.aar`) and notes: <https://github.com/yucheng-watch-s26/yucheng-watch-s26.github.io>
* Sleep units confirmed in seconds from real ring captures: <https://github.com/auroraphtgrp01/ble-sleeping>
* Smarthealth developer (Shenzhen Yucheng Innovation Technology): <https://apps.apple.com/us/app/smarthealth/id1450500729>
* Apple Watch Bluetooth background behaviour: WWDC21 [10005](https://developer.apple.com/videos/play/wwdc2021/10005/),
  WWDC22 [10135](https://developer.apple.com/videos/play/wwdc2022/10135/)

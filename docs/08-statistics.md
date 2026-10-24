# The 24 HDB 630 statistics

Investigated on 2026-09-23–24, HDB 630 firmware **3.33.3**, BTD 700 firmware **3.11.0**. Audio normally travels through the dongle; GAIA travels through a separate Mac/headphone connection.

There are two different levels of evidence here: names and byte representations recovered from Qualcomm's reference client, and vendor counters identified experimentally on one HDB 630. Unresolved records are explicitly left unnamed. A counter that happens to equal 100 is not evidence of battery health.

## Streaming category `0001`

All five names are defined in Qualcomm's `StreamingStatistics.kt`. Sample values below were read from the real headphones.

| ID | Field | Encoding | Example |
| --- | --- | --- | --- |
| `01` | Codec | uint8: 1 SBC, 2 AAC, 3 aptX, 4 aptX HD, 5 aptX Adaptive | `05`: aptX Adaptive |
| `02` | Lossless enabled | uint8: zero false, nonzero true | `00`: disabled |
| `03` | Bitrate | uint32 big endian, bits/second | **Empty**: unavailable |
| `04` | Primary RSSI | int16 big endian | `FF CF`: −49 |
| `05` | Primary link quality | uint16 big endian; `raw / 65535 × 100` | `FF 78`: 65400, **99.794%** |

The statistics codec enum differs from Sennheiser command `0x0800` (where aptX Adaptive is 8). The reference RSSI decoder displays the signed integer without a unit conversion. The response does not identify the primary peer; in a multipoint configuration it is not enough to call this the dongle's RSSI. Link quality is the device's normalized score, not a measured packet-delivery percentage, error rate, latency or audio fidelity rating. An empty bitrate field is not zero bitrate. The lossless field was also empty during native AAC playback; that displays as unavailable, not false.

## Vendor category `0100`

These are the initial values captured at approximately 23:13 EDT. All numbers are unsigned big endian, except where a schema eventually establishes otherwise. Observed durations advance in whole-minute steps. The accumulated values survived ordinary restarts; their complete persistence/reset semantics have not been established.

| ID | Bytes | Initial value | Meaning / evidence |
| --- | ---: | ---: | --- |
| `01` | 2 | 100 | **Startup count**, experimental: 108 → 109 after exactly one acknowledged software restart (`0x060F`). Includes software restarts, not just presses of the power button. |
| `02` | 4 | 10760 | **Powered-on minutes**, experimental: continues with the audio link disconnected. |
| `03` | 2 | 477 | **Playback starts**, experimental: 478 → 479 on native AAC playback start. |
| `04` | 4 | 6359 | **Playback minutes**, experimental: stops with no stream, resumes during AAC; equals sum of `0F`–`13`. |
| `05` | 2 | 4 | Unresolved; call count is a hypothesis. |
| `06` | 4 | 15 | Unresolved; call minutes is a hypothesis. |
| `07` | 4 | 0 | Unresolved. |
| `08` | 2 | 75 | **Noise-control activation count**, experimental: 75 → 76 after restoring ANC. |
| `09` | 4 | 10759 | **Noise-control enabled minutes**, experimental: stopped with ANC disabled; continues in Manual mode, even at 100% transparency. |
| `0A` | 2 | 6 | **Charging sessions**, experimental: 6 → 7 after plugging in charging cable. Not battery wear cycles. |
| `0B` | 4 | 2633 | **Charging minutes**, experimental: 2633 → 2634 during cable test. |
| `0C` | 2 | 42 | Unresolved. |
| `0D` | 2 | 0 | Unresolved. |
| `0E` | 4 | 0 | Unresolved. |
| `0F` | 4 | 281 | **AAC playback minutes**, experimental: 281 → 282 on native AAC, then stops on aptX Adaptive. |
| `10` | 4 | 1 | Audio-time bucket; codec assignment unresolved. |
| `11` | 4 | 6074 | **aptX Adaptive playback minutes**, experimental: stops during AAC and no-stream intervals; resumes on dongle. |
| `12` | 4 | 0 | Audio-time bucket; codec assignment unresolved. |
| `13` | 4 | 3 | Audio-time bucket; codec assignment unresolved. |

The [captured experiment data](https://github.com/steph4n-gh/signal-deck/blob/bafdb60/docs/statistics-observations.json) contains the raw values and independent state readbacks. Each experiment starts with a full snapshot, followed by changed statistic bytes.

## Controlled observations

- **Wear:** removing/replacing the headphones produced physical state `03 → 02 → 03`. No vendor statistic changed just because of that transition. A second removal to attach the cable was also recorded.
- **Charging:** `0x0602` changed `0000 → 0100 → 0000` during a roughly 75-second cable test. IDs `0A` and `0B` each rose by one. Battery remained 90%; ID `01` remained 100.
- **ANC:** switching ANC off for about 85 seconds stopped `09`, while `02`, `04` and `11` continued. Restoring ANC restarted `09` and incremented `08`. The playback-event candidate `03` also rose once, so that ID needs its own test.
- **Audio processing:** Off, graphic EQ and Podcast were read back through `0x0804`. The active duration bucket remained `11`, excluding a simple EQ-mode interpretation for that bucket.
- **Audio path:** disconnecting the dongle gave headphone codec `FF`, sample rate zero; `04` and `11` stopped while `02` and `09` kept advancing. Routing audio directly through the Mac gave Sennheiser codec `01`, statistics codec `02` and 44,100 Hz (AAC). Playback-start counter `03` incremented and duration `0F` advanced. `11` remained stationary during AAC.
- **Transparency with Adaptive on:** a request for 100 read back as zero, so this phase is not valid evidence for transparency counters.
- **Manual transparency:** adaptive mode was disabled and `0x1A03` read back 100, then 50, for separate roughly 85-second intervals. No new vendor counter began advancing. `09` continued at 100% transparency: it tracks the noise-control feature being enabled, not minutes of effective acoustic cancellation. The original 0% balance and adaptive setting were restored.
- **Restart / reconnection:** after several user-confirmed off/on cycles and Mac re-pairing, `01` rose 100 → 106. This supports a startup counter, but the exact number of restarts was not counted. Playback total `04` stayed 6397, AAC `0F` stayed 282, Adaptive `11` stayed 6111, charging sessions stayed 7, and charging minutes stayed 2634. During a further 90-second no-stream observation, `02` and `09` advanced while playback counters stayed fixed. Streaming records were all empty with no audio stream. The headset also reported wind Auto and Adaptive off after recovery; this interval is not a controlled ANC experiment.
- **Controlled software restart:** category page before restart reported `01=006C` (108). One acknowledged `0x060F` restart was sent, the Mac reconnected, and `01=006D` (109) was read back. This identifies startup count independently of the earlier uncounted button presses. Other accumulated values persisted.
- The initial duration identity is exact: `281 + 1 + 6074 + 0 + 3 = 6359`. Repeated samples preserve `0F + 10 + 11 + 12 + 13 = 04`.

Counter changes are batched roughly once a minute. Reading immediately after a setting change is insufficient. These experiments change one setting/path at a time and capture its independent state getter alongside the statistics. Original settings are restored.

## Read-only wire protocol

Vendor is **`0x001D`**, not `0x0495` (whose `0x1800` is a setter for an unrelated feature).

- `0x1800` get categories, payload `[lastCategoryHi, lastCategoryLo]`. Start at zero. Response `[more, categoryHi, categoryLo, ...]`.
- `0x1801` get a page, payload `[categoryHi, categoryLo, lastStatisticID]`. Start statistic ID zero. Response `[more, categoryHi, categoryLo, {id, flags, length, value...}...]`.
- Use the last returned statistic ID for the next page. HDB 630 sends at most five records per page; category `0100` uses starts `0, 5, 10, 15`.
- All observed flags are zero. Preserve unknown flags and bytes; do not assign a numeric interpretation to future encodings blindly.
- `0x1802` is a documented getter for specific descriptors, but the app currently uses the observed page getter.

The parser rejects truncated fields, wrong categories, duplicate/out-of-order IDs and non-progressing continuation pages. Empty data remains unavailable. No setters, reset requests, firmware commands or cloud uploads are part of the sampler.

## Reproduction

Quit HDB 630 Control first, so only one program owns its RFCOMM control channel. Keep the dongle's audio connection active.

```sh
swiftc -parse-as-library Bluetooth/Models.swift Bluetooth/GAIAProtocol.swift \
  Bluetooth/BluetoothManager.swift tools/cli_statistics.swift \
  -import-objc-header HDB630Control-Bridging-Header.h -o /tmp/hdb-statistics
/tmp/hdb-statistics 24 5 > /tmp/hdb-statistics.jsonl
open "$HOME/Applications/HDB630Control.app"
```

The output contains all 24 raw records plus timestamps, wear, charging, battery, codec, stream rate, audio mode and ANC state. It omits serial numbers, Bluetooth addresses and peer names. Sampling is bounded to 360 records with intervals of 2–60 seconds, and closes only RFCOMM on exit. It does not automatically reconnect after power cycling; run it again.

Parser/decoder checks use captured packets:

```sh
swiftc -parse-as-library Bluetooth/Models.swift tools/test-statistics.swift -o /tmp/test-statistics
/tmp/test-statistics
```

## Sources and limits

- [Qualcomm streaming-statistics definitions](https://github.com/boycechan/gaia-client-android/blob/e520ca78d178ae52e225154280739411584d2d59/app/src/main/java/com/qualcomm/qti/gaiaclient/ui/settings/statistics/definitions/StreamingStatistics.kt), Qualcomm-copyrighted reference source in a public mirror. Used to establish protocol facts, not copied into the app.
- [Qualcomm statistics plugin](https://github.com/boycechan/gaia-client-android/blob/e520ca78d178ae52e225154280739411584d2d59/app-core/src/main/java/com/qualcomm/qti/gaiaclient/core/gaia/qtil/plugins/v3/V3StatisticsPlugin.kt), for pagination and record encoding.
- Smart Control **4.9.3** (`com.sennheiser.control`, build 147651), static inspection of `assets/app/bundle.js`, `StatisticsService.getAllStatisticsForCategory`. It reads IDs and raw values and sends them as telemetry; it does **not** label the 19 records. Downloaded XAPK SHA1 `15e537f7831fefbaa0339467af7921640c6ed063` matched the distribution listing.
- Smart Control Plus **1.2.4** (build 59818) and **1.6.1** (build 71159) were also inspected statically. The older binary retains class/file names for the GAIA statistics reader and telemetry uploader, but no mapping for vendor category 256 was found. The newer app encrypts configuration assets. No APK was installed or executed, and no telemetry service was called.
- The Plus 1.2.4 XAPK SHA256 was `2188d730c9a8249412c495ac47df9521fbce8d5f8898ad4fe2423535c84f8e62`; Plus 1.6.1 SHA1 was `80902b03444b5f8290657373cceb4511f0c2d796`.

Phone-app telemetry availability does not imply continuous access to raw ANC microphones, motion sensors, battery health, radio retransmissions or firmware internals. Those remain separate questions.

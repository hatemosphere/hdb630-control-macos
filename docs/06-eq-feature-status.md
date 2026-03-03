# User EQ Feature Status (Feature 8, base 0x1000)

## Command Map

| Cmd | Property | Type | Payload Format | Status |
|------|----------|------|----------------|--------|
| 0x1000 | configuration | GET | - → `[bands, min_gain, max_gain, 0, 0]` | **Probed** |
| 0x1001 | set_slider_gain | SET | `[band, gain_i8]` → ack | **In App** |
| 0x1002 | slider_gain | GET | `[band]` → `[gain_i8]` | **In App** |
| 0x1003 | param_group | GET | `[group_idx]` → `[g0, g1, g2, g3, g4]` | **Probed** |
| 0x1004 | set_custom_eq_knob | SET | ? | Error 01 (not supported on this model?) |
| 0x1005 | custom_eq_knob_value | GET | ? | Error 01 |
| 0x1006 | set_level_shift | SET | ? | Error 01 |
| 0x1007 | level_shift | GET | ? | Error 01 |
| 0x1008 | set_sub_mode | SET | `[0/1]` → ack | **In App** (bass boost: 0=off, 1=on) |
| 0x1009 | sub_mode | GET | - → `[0/1]` | **In App** (bass boost: 0=off, 1=on) |
| 0x100A | set_stage_frequency | SET | `[stage, freq_hi, freq_lo]` → ack | **Probed** |
| 0x100B | stage_frequency | GET | `[stage]` → `[stage, freq_hi, freq_lo]` | **Probed** |
| 0x100C | set_stage_q | SET | `[stage, q_hi, q_lo]` → ack | Untested (likely same pattern) |
| 0x100D | stage_q | GET | `[stage]` → `[stage, q_hi, q_lo]` | **Probed** |
| 0x100E | set_stage_filter_type | SET | `[stage, type]` → ack | Untested (likely same pattern) |
| 0x100F | stage_filter_type | GET | `[stage]` → `[stage, type]` or `[]` | **Probed** |
| 0x1010 | set_stage_gain | SET | `[stage, gain_hi, gain_lo]` → ack | Untested (likely same pattern) |
| 0x1011 | stage_gain | GET | `[stage]` → `[stage, gain_hi, gain_lo]` | **Probed** |
| 0x1012 | set_pre_gain | SET | `[gain_hi, gain_lo]` → ack | **Probed** |
| 0x1013 | pre_gain | GET | - → `[gain_hi, gain_lo]` | **Probed** |
| 0x1014 | device_headroom | GET | - → `[headroom_hi, headroom_lo]` | **Probed** |

## What's Already in the App

### Implemented and working
- **5-band graphic EQ** (0x1001/0x1002): set/get per-band gain, slider UI, preset selection
- **Bass boost** (0x1008/0x1009): on/off toggle
- **EQ notification** (0x1082): receives all 5 band gains when changed externally
- **EQ presets**: Neutral, Rock, Pop, Dance, Hip-Hop, Classical, Movie, Jazz with hard-coded gains
- **Audio mode** (0x0803/0x0804): genericAudio feature — used for podcast mode toggle (mode=2), but actually controls all audio modes (0-5)
- **Crossfeed** (0x0E01/0x0E02): low/high/off (separate feature, not userEq)

### Defined in GAIAProtocol.swift but not fully used
- `cmdSetEQBand` (0x1001), `cmdGetEQ` (0x1002), `cmdSetBassBoost` (0x1008), `cmdGetBassBoost` (0x1009)
- Notification IDs: `notifEQ` (0x1082), `respEQBand` (0x1101), `notifBassBoost` (0x1089/0x1088)

## What We Know but Haven't Implemented

### Configuration (0x1000)
Response: `05 C4 3C 00 00`

Parsing confirmed from Blutter (`EqualizerDeviceConfiguration.fromValue()`):
- `byte[0]` = 0x05 → 5 bands (int64 field)
- `byte[1]` = 0xC4 → signed 7-bit: `(0xC4 & 0x7F) - (0xC4 & 0x80)` = 68 - 128 = -60 → ÷10 = **-6.0 dB** min gain
- `byte[2]` = 0x3C → signed 7-bit: `(0x3C & 0x7F) - (0x3C & 0x80)` = 60 - 0 = 60 → ÷10 = **+6.0 dB** max gain
- `byte[3]` = 0x00 → int64 field (purpose unclear, possibly number of PEQ stages)
- `byte[4]` = 0x00 → int64 field (purpose unclear, possibly number of param groups)

### Param Group (0x1003)
GET with `[group_index]` returns 5 gain bytes (one per band).
Groups 0-4 all return `00 00 00 00 00` — likely preset storage slots.

### PEQ Stage Parameters (0x100A-0x1011)
All use `[stage_index]` as the first payload byte. 5 stages (0-4).

**Default values observed:**

| Stage | Frequency (Hz) | Q (raw) | Filter Type | Gain |
|-------|---------------|---------|-------------|------|
| 0 | 90 (0x005A) | 0x0800 (2048) | 0x0E (bypass) | 0x0000 (0.0) |
| 1 | 325 (0x0145) | 0x0B5C (2908) | 0x0E (bypass) | 0x0000 (0.0) |
| 2 | 1500 (0x05DC) | 0x0B5C (2908) | 0x0E (bypass) | 0x0000 (0.0) |
| 3 | 6500 (0x1964) | 0x0B5C (2908) | 0x0E (bypass) | 0x0000 (0.0) |
| 4 | 6500 (0x1964) | 0x0B5C (2908) | 0x0E (bypass) | 0x0000 (0.0) |

All 16-bit big-endian. Encoding confirmed from Blutter (`_Mapper` in `peq_variant_adapter.dart`):
- **Frequency**: raw Hz (int→int, no conversion)
- **Q**: raw ÷ 4096.0 (e.g. 0x0800=2048 → Q=0.5, 0x0B5C=2908 → Q≈0.71)
- **Gain**: signed 16-bit ÷ 10.0 for dB (same as slider_gain, pre-gain)

### Pre-gain (0x1012/0x1013)
SET: `[gain_hi, gain_lo]`, GET: response `[gain_hi, gain_lo]`
16-bit signed big-endian, ÷10 for dB. Verified: SET `[0, 10]` → reads back `00 0A` (+1.0 dB).

### Device Headroom (0x1014)
Read-only. Response: `00 1E` = 30 → 3.0 dB headroom.

### Filter Types (from Blutter enum)
| Value | Type |
|-------|------|
| 0 | gain |
| 1 | lowPassFirstOrder |
| 2 | highPassFirstOrder |
| 3 | allPassFirstOrder |
| 4 | lowShelfFirstOrder |
| 5 | highShelfFirstOrder |
| 6 | tiltFirstOrder |
| 7 | lowPassSecondOrder |
| 8 | highPassSecondOrder |
| 9 | allPassSecondOrder |
| 10 | highShelfSecondOrder |
| 11 | lowShelfSecondOrder |
| 12 | tiltSecondOrder |
| 13 | peq |
| 14 | bypass |

### Audio Modes (from Blutter enum)
| Value | Mode |
|-------|------|
| 0 | off |
| 1 | userEq (graphic 5-band) |
| 2 | podcastMode |
| 3 | personalizedSound |
| 4 | parametricEq |
| 5 | hearingEnhancement |

**Audio mode is managed via genericAudio feature (feature 4, base 0x0800):**
- SET: `0x0803` (set_audio_mode) — payload `[mode_byte]`
- GET: `0x0804` (audio_mode) — response `[mode_byte]`
- Notification: `0x0884` (audio_mode GET | 0x0080)

These are the **same commands** already used for "podcast mode" — podcast is just mode value 2.
To switch to parametric EQ, send `set_audio_mode` with value 4.

## Remaining Unknowns

1. **0x1004/0x1005 (custom_eq_knob)**: Always returns error 01 — not supported on HDB 630
2. **0x1006/0x1007 (level_shift)**: Always returns error 01 — not supported on HDB 630
3. **Stage frequency defaults for stages 3 & 4**: Both show 6500 Hz (duplicate). Likely default "unused" values since all filters start as bypass.

## Notifications

All notification IDs follow the pattern: GET command | 0x0080.
NotificationHandler classes confirmed in Blutter output for all items marked "confirmed".

| Notification | ID | Payload | Status |
|-------------|------|---------|--------|
| EQ All Bands | 0x1082 | `[g0, g1, g2, g3, g4]` (5 × int8) | **In App** |
| EQ Single Band ACK | 0x1101 | `[band, gain]` | **In App** (ignored) |
| Bass Boost | 0x1089 | `[0/1]` | **In App** |
| Bass Boost Alt | 0x1088 | `[0/1]` | **In App** |
| Stage Frequency | 0x108B | `[stage, freq_hi, freq_lo]` | Confirmed |
| Stage Q | 0x108D | `[stage, q_hi, q_lo]` | Confirmed |
| Stage Filter Type | 0x108F | `[stage, type]` | Confirmed |
| Stage Gain | 0x1091 | `[stage, gain_hi, gain_lo]` | Confirmed |
| Audio Mode | 0x0884 | `[mode_byte]` | Confirmed (genericAudio feature) |

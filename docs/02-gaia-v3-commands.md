# GAIA v3 Command Reference — HDB 630

All commands are Sennheiser vendor (`0x0495`) unless noted otherwise.

Response cmd = request cmd | 0x0100. Error cmd = request cmd | 0x0180.

## Device Info

| Command | ID | Payload | Response | Notes |
|---------|------|---------|----------|-------|
| Get Serial | 0x0003 | - | ASCII string | Vendor: Qualcomm (0x001D) |
| Get Firmware | 0x1202 | - | [major, minor, patch] | e.g. `03 21 03` = 3.33.3 |
| Get Codec | 0x0800 | - | [codec_id] | See codec table below |
| Get Stream Sample Rate | 0x081A | - | big-endian uint32 Hz | HDB 630 returned `00 00 BB 80` (48 kHz) during streaming; notification `0x089A` uses the same value |
| Get Charging | 0x0602 | - | [status] | 0=disconnected, 1=charging, 2=complete |
| Get Battery | 0x0603 | - | [percent] | 0-100 |
| Get Physical Device State | 0x0402 | - | [state, optional second-side state] | 1=in case, 2=off head, 3=on head; HDB 630 returned `03` while worn; notification `0x0482` |

Qualcomm vendor `0x001D` also exposes read-only statistics: `0x1800` enumerates category IDs and `0x1801` returns paginated statistic records. On this HDB 630, categories `0x0001` and `0x0100` returned 5 and 19 records respectively. The five streaming fields are mapped from Qualcomm client source; several of the 19 vendor counters are mapped by controlled experiments. See [the complete statistics investigation](08-statistics.md) for the ID table, units and remaining unknowns.

### Wireless resolution and restart

| Command | ID | Payload / response |
| --- | --- | --- |
| Get compatibility preference | `0x0406` | `00` = High Resolution, `01` = Standard |
| Set compatibility preference | `0x0405` | One byte, same inverted mapping; restart required |
| Normal restart | `0x060F` | No payload; retains settings and pairings |

Verified on HDB 630 3.33.3: `0406=01` accompanied 48 kHz; writing `0405 [00]`, reading it back and performing one `060F` restart restored `081A=00017700` (96 kHz). [Evidence and reconnection behavior](09-wireless-resolution.md).

### Codec IDs

| ID | Codec |
|----|-------|
| 0 | SBC |
| 1 | AAC |
| 2 | aptX |
| 3 | aptX Low Latency |
| 5 | aptX HD |
| 8 | aptX Adaptive |
| 9 | aptX Lossless |
| 10 | LC3 |
| 255 | None / disconnected |

## ANC

| Command | ID | Payload | Response | Notes |
|---------|------|---------|----------|-------|
| Set ANC Status | 0x1A04 | [0/1] | ack | Global ANC on/off |
| Get ANC Status | 0x1A05 | - | [0/1] | |
| Set ANC Mode | 0x1A00 | [mode, state] | ack | See mode table |
| Get ANC Mode | 0x1A01 | - | [m1,s1,m2,s2,m3,s3] | 6 bytes, 3 mode/state pairs |

### ANC Modes and States

| Mode | ID | States |
|------|----|--------|
| Anti-Wind | 1 | 0=off, 1=max, 2=auto |
| Comfort | 2 | 0=off, 1=on |
| Adaptive | 3 | 0=off, 1=on |

The 6-byte GET response always returns all 3 modes in order: `[01, s1, 02, s2, 03, s3]`.
Sennheiser's [HDB 630 manual](https://cdn.sennheiser-hearing.com/product-documents/product-downloads/hdb-630/Instruction%20manual%20HDB%20630/Instruction_manual_HDB_630.pdf) describes Off, Auto, and Max as **wind-noise reduction**, separate from overall ANC intensity. The 0/1/2 wire mapping is corroborated by device write/readback and [m4-companion's GAIA implementation](https://github.com/Zhengyang-Liu/m4-companion/blob/main/Sources/MomentumCore/MomentumControls.swift); it is not an objective measurement of acoustic effect. Adaptive ANC can change cancellation during a comparison, and a high manual transparency level intentionally passes through outside sound.
The HDB 630 manual documents Adaptive ANC and Wind Noise Reduction, but does not define the acoustic effect of mode 2. The app exposes mode 2 only as an undocumented Comfort flag. Successful write/readback does not establish what it does to the sound; it is unrelated to the documented Comfort Call feature.

## Transparency

| Command | ID | Payload | Response | Notes |
|---------|------|---------|----------|-------|
| Set Transparency | 0x1A02 | [level] | ack | 0-100 |
| Get Transparency | 0x1A03 | - | [level] | |

Transparency only works when ANC is on and Adaptive mode is off. If Adaptive is on, the headphones manage transparency automatically.

## EQ

| Command | ID | Payload | Response | Notes |
|---------|------|---------|----------|-------|
| Set EQ Band | 0x1001 | [band, gain] | ack | band 0-4, gain is int8 (dB x 10) |
| Get EQ Band | 0x1002 | [band] | [band, gain] | Per-band only; bulk GET (no payload) returns error |

Notification 0x1082 delivers all 5 bands at once when EQ changes.

### Band Frequencies

| Band | Frequency |
|------|-----------|
| 0 | 50 Hz |
| 1 | 250 Hz |
| 2 | 800 Hz |
| 3 | 3 kHz |
| 4 | 8 kHz |

### Gain Encoding

Gain is a signed int8, representing dB x 10. So `0x14` (20) = +2.0 dB, `0xE0` (-32) = -3.2 dB.

### Presets (gain values as dB x 10)

| Preset | 50Hz | 250Hz | 800Hz | 3kHz | 8kHz |
|--------|------|-------|-------|------|------|
| Neutral | 0 | 0 | 0 | 0 | 0 |
| Rock | 0 | 20 | 25 | 15 | -20 |
| Pop | 0 | -25 | 0 | 25 | 0 |
| Dance | 35 | 20 | -15 | 15 | 30 |
| Hip-Hop | 30 | 15 | -15 | 0 | -15 |
| Classical | -20 | -15 | 0 | 35 | 40 |
| Movie | 0 | 0 | 20 | 20 | -20 |
| Jazz | -32 | 0 | 22 | 22 | 0 |

## Bass Boost

| Command | ID | Payload | Response | Notes |
|---------|------|---------|----------|-------|
| Set Bass Boost | 0x1008 | [0/1] | ack | |
| Get Bass Boost | 0x1009 | - | [0/1] | |

## Podcast Mode

| Command | ID | Payload | Response | Notes |
|---------|------|---------|----------|-------|
| Set Podcast | 0x0803 | [0x00, val] | ack | val: 0x02=on, 0x01=off |
| Get Podcast | 0x0804 | - | [0x00, val] | |

The extra `0x00` prefix byte is always there. No idea why.

Podcast mode disables EQ and bass boost while active. When turning podcast mode off, you need to re-send the EQ band values to restore them.

## Sidetone (Call Transparency)

| Command | ID | Payload | Response | Notes |
|---------|------|---------|----------|-------|
| Set Sidetone | 0x0805 | [level] | ack | 0=off, 1-4 = levels |
| Get Sidetone | 0x0806 | - | [level] | |
| Set Auto-Pause | 0x1800 | [0/1] | ack | 0=keep playing, 1=pause audio when sidetone enabled |
| Get Auto-Pause | 0x1801 | - | [0/1] | |

Sending sidetone level 5 or higher returns an error. Only 0-4 are valid.

Auto-Pause (`TransparentHearing_Mode` in m4.json) pauses audio playback when Call Transparency / sidetone is activated. Discovered via packet capture of the iOS app.

## Crossfeed

| Command | ID | Payload | Response | Notes |
|---------|------|---------|----------|-------|
| Set Crossfeed | 0x2E00 | [val] | ack | 0=low, 1=high, 2=off |
| Get Crossfeed | 0x2E01 | - | [val] | |

The value mapping is counterintuitive: 0 is not "off" — it's "low." Off is 2.

## Settings

| Command | ID | Payload | Response | Notes |
|---------|------|---------|----------|-------|
| Set On-Head Detection | 0x0400 | [0/1] | ack | Disables dependent features when off |
| Get On-Head Detection | 0x0401 | - | [0/1] | |
| Set Smart Pause | 0x080C | [0/1] | ack | Pause on ear removal (requires on-head detection) |
| Get Smart Pause | 0x080D | - | [0/1] | |
| Set Auto-Answer Calls | 0x080A | [0/1] | ack | Auto-answer incoming calls (requires on-head detection) |
| Get Auto-Answer Calls | 0x080B | - | [0/1] | |
| Set Comfort Call | 0x0814 | [0/1] | ack | |
| Get Comfort Call | 0x0815 | - | [0/1] | |
| Set Auto Power Off | 0x0600 | [0x00, sec_hi, sec_lo] | ack | Timer ID 0 = auto power off; seconds big-endian |
| Get Auto Power Off | 0x0601 | [0x00] | [0x00, sec_hi, sec_lo] | Common values: 0 (off), 900 (15m), 1800 (30m), 3600 (60m) |

On-Head Detection controls the proximity sensor. Disabling it automatically disables Smart Pause, Auto-Answer Calls, and Auto Power Off on the headphones. Re-enabling restores previous states from headphone memory.

## Connection Management

| Command | ID | Payload | Response | Notes |
|---------|------|---------|----------|-------|
| Get Paired Device Count | 0x1400 | - | [count_BE 2B] | Big-endian uint16 |
| Get Device Info | 0x1401 | [index] | [idx, priority, connStatus, name...] | connStatus: 0=disconnected, 1=connected |
| Connect Device | 0x1402 | [index] | ack | Error reply 0x1582 if refused |
| Disconnect Device | 0x1403 | [index] | ack | Error reply 0x1583 if refused |
| Remove (unpair) Device | 0x1405 | [index] | ack | Error reply 0x1585 if refused |
| Get Connection Status | 0x1404 | [index] | [idx, status] | |
| Get Own Device Index | 0x1407 | - | [index] | Which slot "this device" occupies |
| Get Max BT Connections | 0x1409 | - | [max] | Returns 2 on HDB 630 |

## Notification IDs

These are pushed by the headphones after you register for the corresponding feature. Notification cmd = GET cmd | 0x0080.

| Notification | ID | Feature | Payload | Notes |
|-------------|------|---------|---------|-------|
| ANC Mode | 0x1A81 | ANC (13) | [m1,s1,m2,s2,m3,s3] | |
| ANC Status | 0x1A85 | ANC (13) | [0/1] | |
| Transparency | 0x1A83 | Transparent Hearing (12) | [level] | |
| Battery | 0x0683 | Battery (3) | [percent] | |
| Charging | 0x0682 | Battery (3) | [status] | |
| Codec | 0x0880 | Generic Audio (4) | [codec_id] | |
| EQ All Bands | 0x1082 | User EQ (8) | [b0, b1, b2, b3, b4] | 5 signed int8 values |
| EQ Single Band | 0x1101 | User EQ (8) | [band, gain] | |
| Bass Boost | 0x1089 | User EQ (8) | [0/1] | |
| Podcast | 0x0884 | Generic Audio (4) | [0x00, val] | |
| Smart Pause | 0x088D | Generic Audio (4) | [0/1] | |
| Comfort Call | 0x0895 | Generic Audio (4) | [0/1] | |
| Connection | 0x1484 | Device Mgmt (10) | [index, status] | |
| Crossfeed | 0x2E81 | - | [val] | No push — polling only |
| Sidetone | 0x0886 | Generic Audio (4) | [level] | No push — polling only |

### No-Push Settings

The following settings don't fire push notifications and must be polled:
- Crossfeed, sidetone, auto-pause
- On-head detection, smart pause, auto-answer calls, comfort call, auto power off

We poll every 2 seconds while the popover is open.

### Mystery Notification

Notification 0x089A reports the active headphone stream sample rate as a big-endian 32-bit integer (for example 44100 or 48000 Hz). The app displays it in Signal Lab.

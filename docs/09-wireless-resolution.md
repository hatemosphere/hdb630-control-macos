# Wireless High Resolution without the phone

Verified on HDB 630 firmware **3.33.3**, BTD 700 **3.11.0**, 2026-09-24.

The Mac's USB sample rate, the dongle's listening mode and the headphone's resolution preference are separate settings. Selecting Music sets the first two; the headphone must also permit High Resolution. Signal Lab reports both the configured preference and the actual stream rate.

## Commands

All commands below use Sennheiser vendor `0x0495`.

| Command | Meaning | Payload / response |
| --- | --- | --- |
| `0406` | Get Bluetooth compatibility preference | `00` = High Resolution, `01` = Standard / better compatibility |
| `0405` | Set Bluetooth compatibility preference | One byte, same **inverted** mapping |
| `060F` | Normal software restart | Empty request and response; retains settings and pairings |
| `0818` | Headphone low-latency flag, read only in this investigation | `00` was reported |
| `081A` | Actual headphone stream rate | Big-endian uint32 Hz |

Source: static inspection of Smart Control 4.9.3's `m4.json`, `tw4.json` and `3823.js`. The JSON defines compatibility-mode getter/setter IDs and values. The audio-resolution screen names the inverted compatibility flag **High Resolution**, writes it, and requires a restart. `tw4.json` separately defines `Reboot_Gaia` as `060F`; it is not factory reset. The archived APK hash and inspection provenance are recorded in [the statistics investigation](08-statistics.md#sources-and-limits).

Smart Control Plus 1.2.4 also contains `GetAptX96kHzSupportCommand` and `SetAptX96kHzSupportCommand` names. Those names alone did not establish wire IDs; the older app's concrete command definitions and HDB 630 live results establish the implementation above.

## Observed recovery

After pairing recovery, Music was selected, Mac USB was 96 kHz, but both the dongle and headphone reported 48 kHz. Video → Music did not change that. The headphone returned compatibility `01` and low-latency `00`.

1. Wrote `0405 [00]` and read back `0406 → 00`.
2. The active stream remained 48 kHz before restart.
3. Sent `060F` once and received an empty successful response.
4. Reconnected the already paired Mac without removing or re-pairing anything.
5. Read `0406 → 00`, `0818 → 00`, `0800 → 08` (aptX Adaptive), and `081A → 00017700` (**96,000 Hz**).
6. The startup statistic advanced exactly **108 → 109**. See [raw evidence](https://github.com/steph4n-gh/signal-deck/blob/bafdb60/docs/statistics-observations.json).

The app offers an explicit **Enable / Disable & restart headphones** action under **Headphones → Settings → Wireless audio**. It verifies the preference before sending a normal restart, waits for boot, and reconnects that same paired device off the UI thread. Unsupported or malformed preference responses remain unavailable. The live stream rate remains authoritative: enabling the preference does not promise that every source or codec will use 96 kHz.

Production-controller validation: applying High Resolution through `HeadphoneController.setHighResolution` completed the software restart and reopened RFCOMM automatically. The startup count advanced 109 → 110, the preference remained enabled, no control error remained, and a settled read returned 96,000 Hz. The installed app UI then reported aptX Adaptive, 24-bit/96 kHz on both the USB and dongle links.

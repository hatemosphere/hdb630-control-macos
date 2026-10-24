# BTD 700 on macOS

The BTD 700 has two independent USB interfaces relevant here:

- USB audio carries the Mac's sound to the dongle. The dongle transmits it to the HDB 630 over Bluetooth.
- A vendor HID interface accepts dongle settings and returns live status. The macOS app uses this interface through IOKit. No custom driver is needed.

The headphone controls in this project still use a direct Mac-to-headphone Bluetooth Classic RFCOMM connection. The dongle's USB HID interface controls the dongle; it does not relay GAIA commands to the headphones. With dongle audio and Mac headphone control together, the HDB 630's two multipoint slots are occupied.

## HID interface

The tested BTD 700 enumerates as vendor `0x3542`, product `0x3001`. The relevant HID collection has usage page `0xFFA2`, usage `1`, and 64-byte reports with ID `0x34`.

Host commands use `[0x34, 0xFE, command, payload_length, payload..., zero_padding]`. Replies use `[0x34, 0xFF, command, payload_length, payload..., zero_padding]`. Unsolicited events use marker `0xFC`. The app currently uses commands:

| ID | Purpose |
| --- | --- |
| `0x12` | Firmware version: major, minor, build (16-bit little-endian) |
| `0x06` | Connection state |
| `0x01` / `0x02` | Get / set audio mode |
| `0x03` | Codec capability mask reported by the dongle |
| `0x04` | Request codec mask |
| `0x05` | Active codec |
| `0x08` | Active bit depth and sample rate |
| `0x07` | LE Audio connection state |
| `0x15` | Sink transport (Classic, LE Audio, or dual) |
| `0x14` | Request connection / disconnection |

Not used by the app, but documented by btd700ctl: `0x09`/`0x0A` broadcast info (state, quality, encryption), `0x0B`/`0x0C` broadcast key, `0x0D`/`0x0E` broadcast name, `0x13` factory reset, `0x17` gaming availability (errors on the tested firmware per btd700ctl).

Unsolicited events (`0xFC`) carry an event ID in byte 2: `0x02` audio mode, `0x03` supported codecs, `0x04` codec in use, `0x0F` connection state, `0x10` LE Audio state, `0x11` audio quality, `0x16` sink transport, `0x17` gaming availability. Each event payload has the same layout as the matching status reply (`0x02`->`0x01`, `0x03`->`0x03`, `0x04`->`0x05` codec mask, `0x0F`->`0x06`, `0x10`->`0x07`, `0x11`->`0x08`, `0x16`->`0x15`), captured on firmware 3.11.0 during a dongle disconnect/reconnect and a mode change. The app applies events directly. No codec event arrives when the link drops, so a state event also re-reads `0x05`. Unknown events trigger a full refresh. The audio-mode reply and event carry a third, undocumented byte (`01` so far).

These identifiers were documented by [btd700ctl](https://github.com/sobalap/btd700ctl). The macOS implementation was tested directly against a plugged-in BTD 700 on firmware 3.11.0. It returned streaming state, Gaming mode, aptX Adaptive, and 24-bit/48-kHz audio. Changing the mode to High Quality and back returned success (`0x00`) and read back correctly. Codec requests returned status `0x01` and left aptX Adaptive active; the app reports that rejection.

The read-only `0x07` and `0x15` status commands returned `01` and `01` with the HDB 630 connected. In btd700ctl's enum mapping, these mean LE Audio disconnected and Classic Bluetooth sink transport. They describe the dongle-to-headphone link, not the Mac's separate direct control connection.

The currently active audio quality is a report from the dongle, not a promise of source or headphone capability. To reach 96 kHz, the Mac's USB output format and the headphones' Hi-Res priority setting must also allow it.
The Video and Music buttons now set both the dongle mode and Mac USB output rate (48 and 96 kHz respectively), then read back both. The USB rate is also independently selectable. Sennheiser's HDB 630 manual says the headphone Audio Mode Priority must be set to High Resolution and the headphones restarted for 96 kHz wireless streaming. That setting is now available under **Headphones → Settings → Wireless audio**, with write/readback and a normal software restart. See [wireless resolution](09-wireless-resolution.md). The UI reports the actual link format.

Live validation on 2026-09-23: selecting Video yielded 48 kHz on the Mac USB output and BTD 700 link. Selecting Music yielded 96 kHz on the Mac USB output, BTD 700 link, and the HDB 630's `0x081A` stream-rate report. Returning to Video restored 48 kHz. This particular headset already had Hi-Res priority enabled, so the wireless link could reach 96 kHz without changing its headphone setting during the test.

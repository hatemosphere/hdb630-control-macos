# HDB 630 macOS Controls

Native macOS menu bar app to control Sennheiser HDB 630 headphones -- because Sennheiser only made a mobile app and forgot desktops exist.

<img src="screenshot.png" width="300">

## How it works

Communicates with the headphones over Bluetooth Classic RFCOMM using the GAIA v3 protocol (Qualcomm). Despite the Airoha chipset, HDB 630 speaks GAIA v3 -- discovered through reverse engineering the mobile app and Sennheiser's desktop client.

Connection flow:
1. SDP discovery to find the GAIA RFCOMM channel
2. Open RFCOMM channel
3. Register for push notifications (10 Sennheiser features + 1 Qualcomm)
4. Fetch all device state
5. Real-time updates via push notifications + 2-second polling for settings without notification support

## Building

Requires macOS 13+ and Xcode 15+.

```
open HDB630Control/HDB630Control.xcodeproj
```

Or with XcodeGen:
```
cd HDB630Control && xcodegen && open HDB630Control.xcodeproj
```

Build and run. The app appears as a headphones icon in the menu bar.

## Project Structure

```
HDB630Control/
  App/
    AppDelegate.swift          -- Menu bar item, popover, polling
    HDB630ControlApp.swift     -- SwiftUI app entry point
  Bluetooth/
    GAIAProtocol.swift         -- GAIA v3 packet builder/parser
    BluetoothManager.swift     -- SDP lookup, RFCOMM I/O
    HeadphoneController.swift  -- Device state + all get/set commands
  UI/
    StatusBarView.swift        -- SwiftUI popover UI

tools/                         -- CLI probe/test scripts used during RE
docs/                          -- Protocol docs and RE guide
```

## Features

**Noise Control**
- ANC modes: Adaptive, Comfort, Anti-Wind (off/max/auto)
- Global ANC on/off
- Transparency level (0-100)

**Audio**
- Preset EQ (Neutral, Rock, Pop, Dance, Hip-Hop, Classical, Movie, Jazz) with 5-band slider gains and custom detection
- Parametric EQ (5-band PEQ with per-stage frequency, gain, Q, filter type, and pre-gain)
- Bass boost
- Podcast mode
- Crossfeed (off/low/high)
- Codec display (SBC, AAC, aptX, aptX HD, aptX Adaptive, LC3)

**Call**
- Call Transparency / sidetone (off + 4 levels)
- Auto-Pause (pause audio when Call Transparency is active)
- Comfort Call

**Settings**
- On-Head Detection (auto-disables Smart Pause, Auto-Answer, Auto Power Off when off)
- Smart Pause
- Auto-Answer Calls
- Auto Power Off (off/15m/30m/60m)

**Device Info**
- Battery level + charging status
- Firmware version, serial number
- Connected devices (multipoint, view-only)

## Known Limitations

- Crossfeed, sidetone, auto-pause, on-head detection, smart pause, auto-answer, comfort call, and auto power off don't fire push notifications -- polled every 2 seconds while popover is open
- BTD 700 USB dongle works for audio but control still goes directly to headphones via separate BT connection
- Multipoint is intentionally view-only, to not cut own connection
- Custom EQ presets created in the mobile app show as "Custom" -- headphones only store raw band gains, preset names live in the phone app's local storage

## BTD 700 Dongle & Multipoint

The BTD 700 USB-C dongle appears as a standard USB audio device. Audio goes: Mac -> USB -> dongle -> Bluetooth -> headphones. This gives you high-quality codecs (aptX Adaptive) that aren't available over regular macOS Bluetooth.

Control (this app) connects directly to the headphones via a **separate** Bluetooth Classic connection. So if you want BTD 700 audio + this app from the same Mac, that's **both multipoint slots taken** -- no room for a third device (e.g. phone):

1. BTD 700 dongle (audio, high-quality codec)
2. Mac Bluetooth (RFCOMM control via this app)

HDB 630 supports up to 2 simultaneous connections and 3 paired devices. Without the dongle, regular Mac Bluetooth handles both audio and control over a single connection, leaving one slot free for another device.

## License

MIT

# EQ hardware verification, 2026-10-15

The graphic EQ and PEQ controls were exercised on the physical HDB 630 running firmware 3.33.3. The installed app writes values that match fresh GAIA reads through a separate RFCOMM connection. Original settings were restored and independently read back after testing.

## Findings and fixes

| Priority | Failure scenario and evidence | Fix and code reference |
| --- | --- | --- |
| P1 | Setting PEQ pre-gain to -1.5 dB displays -358.5 dB after notification `0x1093 F1 FF`. The stored value and GET response remain correct. A second capture shows -2 dB as GET `FF EC`, notification `EC FF`, and the old display as -486.5 dB. | Decode pre-gain notifications as signed little-endian. Keep GET replies and other PEQ parameters big-endian. [HeadphoneController.swift](../Bluetooth/HeadphoneController.swift#L956). |
| P2 | A manual 8 kHz edit to +6 dB, followed immediately by Rock, leaves a pending debounce. Its final `[4,60]` write overwrites Rock's `[4,236]` while the UI still shows Rock at -2 dB. Reproduced with the production controller and fake transport. | Cancel pending manual band tasks synchronously when selecting a preset. [HeadphoneController.swift](../Bluetooth/HeadphoneController.swift#L522). |
| P2 | Custom graphic sliders have no accessible control in the original app's accessibility tree. Assistive technology cannot identify or change individual bands. | Give each custom slider a native SwiftUI slider accessibility representation. Label PEQ controls by band and parameter. [StatusBarView.swift](../UI/StatusBarView.swift#L550), [native representation](../UI/StatusBarView.swift#L628). |
| P2 | Direct controller calls accept unsupported numeric values. For example, `setPreGain(-358.5)` publishes and packs that value. Nonfinite values can trap during integer conversion. This is a separate input validation issue, not the cause of the live notification display error. | Bound edits before publication and encoding. Reject nonfinite inputs. Use reported gain limits, 20–20,000 Hz, and Q 0.1–10. [HeadphoneController.swift](../Bluetooth/HeadphoneController.swift#L689). |

The fixes retain the existing debounce tasks, command session, and UI layout. No new transport, polling loop, dependency, or settings layer was added.

## Hardware checks

Only one process owned the GAIA RFCOMM connection at a time. A temporary probe compiled production BluetoothManager, GAIACommandSession, and HeadphoneController. The app was stopped before each independent raw read. The probe sent only the known setting commands and getters listed in the protocol documentation.

- All eight graphic presets passed five-band write/readback checks through the production controller.
- All five graphic bands passed custom positive and negative gain writes. The installed UI also wrote `[-0.5, 1.5, -2, 2.5, -3]` dB. A new connection returned bytes `[251,15,236,25,226]`.
- Bass boost passed on/off checks. Its installed UI write read back as `[1]` before restoration to `[0]`.
- All five PEQ stages passed frequency, Q, signed gain, and Bell filter writes. All 15 filter choices also passed set/get checks on the first stage. Bypass was checked separately on the fifth stage.
- The installed UI set all five stages to Bell with frequencies `[20,200,2000,20000,632]` Hz, Q `[0.5,0.75,1,1.25,1.5]`, and gains `[-1,-0.5,0,0.5,1]` dB. A separate connection confirmed each raw value.
- Positive +1.5 dB and negative -2 dB pre-gain notifications agree with getters after the fix. The installed UI displayed -1.5 dB after its notification, and a separate connection returned `FF F1`.
- The installed app reconnected and displayed the saved PEQ edits after a client restart. Headroom remained 3 dB throughout these checks, matching getter `00 1E`.

These checks verify control writes, stored values, notification decoding, and client reconnect behavior. They do not measure acoustic frequency response or listening quality. No headphone power cycle was performed during this pass.

## Restoration

The baseline was captured before the first write, including inactive PEQ values. Final restoration used exact raw values rather than rounded UI labels.

| Setting | Restored value |
| --- | --- |
| Audio mode | Off |
| Graphic gains | All 0 dB |
| Bass boost | Off |
| PEQ filters | All Bypass |
| PEQ frequencies | 90, 325, 1500, 6500, 6500 Hz |
| PEQ Q raw values | 2048, 2908, 2908, 2908, 2908 |
| PEQ stage gains and pre-gain | All 0 dB |
| Audio output and BTD 700 USB rate | MacBook Pro Speakers, 48,000 Hz |

A new probe process read all 37 captured snapshot entries after restoration. The snapshot matched the original byte for byte. General headphone settings were not changed by the test.

## Software verification and installation

Three focused regressions fail with the previous behavior and pass with the fixes. They cover the pre-gain notification format, pending manual edits after preset selection, and numeric input bounds. The notification test also checks big-endian frequency, Q, gain, and pre-gain GET packets. Run `./tools/test.sh` for the six offline test executables.

The full offline suite and macOS Release build passed. Independent reviewers checked the diff, literal wire assertions, input limits, cancellation behavior, and captured notification format. They found no blocking issues. The comment review retained the single new comment because it documents a captured firmware byte-order exception. Deslop review found no unrelated cleanup to make.

The ad-hoc signed Release bundle was copied exactly to `~/Applications/HDB630Control.app`. Its executable SHA-256 is `77491193a3d3bd88f6917e09b2f068549c29ce25e52447e72ac857722182ae73`. All installed bundle file hashes match the tested bundle. The app still identifies as version 0.1.0, build 1.

Two launches from the temporary build folder hit an IOBluetooth discovery timeout. A process sample showed Apple's coordinator initialization waiting on a semaphore in `pairedDevices()`. The same bundle connected at the installed path and completed the UI checks and a subsequent reconnect. The cause of the temporary-path startup failure remains unresolved. No speculative connection change was added.

Local raw snapshots, probe source, notifications, before-fix failures, build logs, and installation receipts are retained in the ignored `build/eq-hardware/` directory. The previous installed bundle is retained there as `previous-installed.app`.

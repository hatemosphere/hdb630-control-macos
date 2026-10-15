# EQ settings across hardware restarts

On 2026-10-15, HDB 630 firmware 3.33.3 retained the tested graphic EQ and PEQ settings through normal headphone reboots. No application persistence fix was needed. This follow-up adds a repeatable hardware check and extends the [earlier EQ verification](11-eq-hardware-verification-2026-10-15.md).

## Method and results

The test used the documented GAIA `0x060F` normal reboot command. Native IOBluetooth monitoring confirmed that the headphone connection went down and returned. This was a headphone firmware restart, not just an app or RFCOMM channel restart.

The verifier reads 30 raw entries before and after reboot. They include audio mode, configuration, bass boost, pre-gain, headroom, all five graphic gains, and each PEQ stage's frequency, Q, gain, and filter type. It validates response lengths and stage indices. It does not instantiate HeadphoneController or send setting writes, so automatic application of settings cannot conceal a reset. A pass requires a completed disconnect/reconnect and byte-for-byte snapshot equality.

| Run | Active mode | Native connection trace | Result |
| --- | --- | --- | --- |
| Graphic EQ | EQ | Connected, disconnected, connected | All 30 entries retained, including inactive PEQ values. |
| Initial PEQ attempt | PEQ | Connected, disconnected, connected, disconnected, connected | The first verifier required exactly one reconnect. It rejected the extra transition before comparing settings. This failed receipt remains preserved. |
| PEQ retry | PEQ | Connected, disconnected, connected | The corrected verifier accepted the completed restart. All 30 entries retained, including inactive graphic EQ values. |
| Original settings | Off | Connected, disconnected, connected | All 30 entries retained after exact restoration. An independent process then matched all 37 entries in the broader original snapshot. |

The non-default test values were checked against fresh hardware getters before reboot.

| Parameter | Test values, bands 1 through 5 |
| --- | --- |
| Graphic gains | -1.5, +0.5, -0.5, +2, -2 dB |
| Bass boost | On |
| PEQ frequency | 125, 400, 1800, 6000, 10000 Hz |
| PEQ Q | 0.625, 1, 1.5, 2, 3 |
| PEQ gain | -1, +0.5, -0.5, +1.5, -2 dB |
| PEQ filter | Low shelf second order, Bell, low pass second order, high shelf second order, Bypass |
| Pre-gain | -1.5 dB |

The installed app displayed the custom graphic gains and enabled bass boost after the first restart. Switching to PEQ displayed the stored parameters. The freshly built and installed Release then displayed those PEQ parameters after the verified PEQ restart.

## Repeatable check

`tools/check-eq-persistence.sh` compiles the production Bluetooth transport and `tools/cli_eq_persistence.swift`. Quit Signal Deck before using it so one process owns the RFCOMM connection. Use a new output filename for every run.

```sh
./tools/check-eq-persistence.sh build/eq-before.json
./tools/check-eq-persistence.sh --restart build/eq-after-restart.json
```

The first invocation captures a read-only snapshot. The second captures its own before snapshot, reboots the headphones, reconnects, and compares against that snapshot. The report contains the raw values, native connection transitions, changed keys, and pass or error status. Invalid arguments and existing output files exit 2 before connecting. Check failures exit 1. Passes exit 0.

Independent review identified an inherited app SIGTERM handler that could make an interrupted check exit 0. The CLI now restores default SIGTERM behavior immediately after constructing BluetoothManager. A manager-only reproduction exited 0 before that change and terminated with signal 15 afterward. No application signal handling changed.

The initial exact-three-transition check was also too strict for an observed reconnect sequence. The final check requires an initially connected device, an observed disconnection, a connected final state, and successful post-restart reads. It preserves intermediate transitions and rejects missing restart evidence.

## Restoration and installed build

The original baseline was captured before test writes. Restoration used the exact raw values, including inactive PEQ settings and Q values that rounded UI labels cannot represent.

Audio mode is Off. Graphic gains are all 0 dB, bass boost is Off, and all PEQ filters are Bypass. PEQ frequencies are 90, 325, 1500, 6500, and 6500 Hz. Q raw values are 2048, 2908, 2908, 2908, and 2908. PEQ gains and pre-gain are all 0 dB. These values survived the final reboot and matched an independent cold read.

macOS automatically selected HDB 630 as the audio output during the restart sequence. The output was restored to the original MacBook Pro Speakers and confirmed through Core Audio. The BTD 700 USB nominal rate remains 48,000 Hz. Other recorded headphone settings were not changed.

A fresh macOS Release build passed and was ad-hoc signed, installed at `~/Applications/HDB630Control.app`, and checked through the actual UI. The executable SHA-256 is `8d45f60b892e99a092b82008c6c2898180e9b5fe2fdc02d6bf1d07087eac6d73`. All installed bundle hashes match the signed build. Application sources are unchanged from `8bbe617`; this follow-up changes verification tools and documentation. The app still identifies as version 0.1.0, build 1.

Local receipts, the fresh baseline, the initial failed check, the passing restart snapshots, restoration evidence, build logs, and installation hashes are in ignored `build/eq-restart/`. The previous app bundle is retained there as `previous-installed.app`.

Independent final review found no blocking issues. Compilation, shell syntax, invalid-argument exits, existing-report preservation, and all passing raw receipts were checked. Final installed UI checks confirmed the original general settings, both paired-device checkmarks, and the BTD 700 connection with aptX Adaptive at 24 bit and 48 kHz.

This verifies normal firmware reboot behavior on this hardware and firmware. Manual power-button cycling, battery removal, acoustic frequency response, and other firmware versions were not tested.

# BTD 700 USB recovery and sleep verification

On 2026-10-15, Signal Deck recovered from a physical BTD 700 unplug and replug without restarting the app. Fresh HID control writes and USB audio streams worked afterward. Full system sleep recovery remains unverified. No application change was justified by these results.

The test used BTD 700 firmware 3.11.0, HDB 630 firmware 3.33.3, and application sources from `8bbe617`. It extends the [project review](10-project-review-2026-10-15.md) and [EQ restart verification](12-eq-restart-verification-2026-10-15.md).

## Physical USB recovery passed

The user physically removed and reinserted only the BTD 700. A read-only native monitor sampled IOKit USB registry IDs, Core Audio output device IDs, the USB nominal rate, and the default output every 200 ms. It also recorded native workspace sleep and wake notifications. It did not open the HID or RFCOMM control connections.

| Time, UTC | Native observation | Installed app observation |
| --- | --- | --- |
| 17:03:34 | USB registry ID 4295449693, Core Audio device 114, 48 kHz | Connected, Video mode, firmware 3.11.0. |
| 17:20:05 | Both USB and Core Audio device lists became empty. | The app asked for the dongle to be plugged in. Old status and controls cleared. |
| 17:21:02–03 | New USB registry ID 4296743939 appeared, followed by Core Audio device 160. | The app automatically returned to Connected and Video mode. |
| 17:22:46 | Core Audio device 160 changed to 96 kHz after selecting Music. | An active USB stream negotiated aptX Adaptive at 24 bit and 96 kHz. |
| 17:23:00 | The same device returned to 48 kHz after selecting Video. | Original mode and USB rate were restored. |

The installed app kept PID 76193 throughout removal, replug, both sleep attempts, and subsequent control checks. Recovery required neither an app restart nor the Refresh button. An initial idle codec value of None persisted through Refresh, then changed to aptX Adaptive when USB playback began. That was consistent with fresh hardware status before a stream negotiated its format.

The stream checks used 15 seconds of zero-valued PCM through `AVAudioPlayer.currentDevice` set to the BTD 700 UID. Playback completed at both 48 kHz and 96 kHz while the app reported Streaming audio and the corresponding wireless format. Core Audio independently confirmed that MacBook Pro Speakers remained the default output. These checks establish stream operation and reported formats, not acoustic quality.

## Full sleep recovery remains unverified

Two `pmset sleepnow` attempts emitted native `willSleep` and `didWake` notifications. The first pair occurred at 17:23:32 and 17:24:02 UTC. The second pair occurred at 17:26:42 and 17:27:12 UTC. In both attempts, the power log recorded `Jettison timed out(30000 ms)`. Display wake input arrived before the timeout, and the log contained no completed system Sleep or Wake transition. Workspace notifications alone are insufficient evidence of full sleep.

The same app process remained usable after these notifications. After the first attempt, selecting Music changed the USB rate to 96 kHz. A fresh silent stream completed, and the UI reported aptX Adaptive at 24 bit and 96 kHz. Selecting Video restored 48 kHz. After the second attempt, the app still showed Connected, Video, and 24 bit at 48 kHz. The headphone UI also showed its original settings over the independent RFCOMM connection.

Further sleep attempts stopped when the user needed the Mac for other work. No persistent power settings, scheduled wake events, unrelated applications, or USB hub power settings were changed. A completed system sleep followed by fresh HID writes and streaming still needs verification.

## Existing recovery paths and coverage

`Bluetooth/DongleController.swift` handles device removal in `detach()`, clears published status, fails pending work, and changes the device generation. Requests reject replies from an old generation. `recoverAfterWake()` first refreshes the current handle, then detaches and retries discovery if necessary. `App/AppDelegate.swift` calls that recovery from its workspace wake observer and refreshes the audio output state. `App/AudioOutputSwitcher.swift` observes device-list changes and rebinds the nominal-rate listener to the current audio device.

All six executables in `./tools/test.sh` passed. The Core Audio test covers removal, replacement device IDs, listener retry, and cleanup. The dongle tests cover status decoding and cancellation through the snapshot reader. They do not construct the real HID controller or exercise removal during a pending HID request. The physical test covers ordinary removal and replacement, not every callback race. Independent source analysis found no demonstrated defect requiring an implementation change.

## Restoration and installed build

A fresh process read all 37 original headphone entries after testing. Every raw value matched the baseline byte for byte. This includes the inactive EQ and PEQ values. No headphone setting writes were needed. The dongle was restored to Video mode and 48 kHz USB, with MacBook Pro Speakers as the default output.

A fresh Release build passed and was ad-hoc signed, then installed at `~/Applications/HDB630Control.app`. All installed bundle hashes matched the signed candidate. Its executable SHA-256 is `464c5d4bc1806816dbf1e6e3c61fe03c40d304bc28c60b2cc1bbbffa63d19dc0`. The app still identifies as version 0.1.0, build 1. Application sources remain unchanged from `8bbe617`; this follow-up records verification results.

The installed build launched as PID 83550 and displayed the original headphone settings. Its BTD 700 tab showed Connected, Video, 48 kHz USB, and aptX Adaptive at 24 bit and 48 kHz. A live Refresh succeeded. A fresh silent USB stream changed the installed UI to Streaming audio at that format without changing the default output. No new application crash report appeared.

Independent final review found no blocking issues. The reviewer checked the raw connection events, both power-log attempts, all 37 snapshot values, build and test receipts, installed file hashes, and the strict ad-hoc signature check. Comment review found no scoped comments or suppressions to remove. The pre-commit cleanup left the verification-only scope unchanged.

Local receipts are in ignored `build/usb-wake/`, including `native-events.json`, the power logs, stream logs, original and final headphone snapshots, `restoration.json`, the build log, and `installation.json`. The previous installed bundle is retained as `previous-installed.app`. The monitor and stream helper sources are preserved there with their receipts.

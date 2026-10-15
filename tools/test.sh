#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
test_dir=$(mktemp -d build/tests.XXXXXX)

xcrun swiftc -parse-as-library Bluetooth/Models.swift tools/test-statistics.swift -o "$test_dir/statistics"
"$test_dir/statistics"
xcrun swiftc -parse-as-library Bluetooth/GAIAProtocol.swift tools/test-gaia.swift -o "$test_dir/gaia"
"$test_dir/gaia"
xcrun swiftc -swift-version 6 -parse-as-library Bluetooth/GAIAProtocol.swift Bluetooth/GAIACommandSession.swift tools/test-bluetooth-session.swift -o "$test_dir/bluetooth-session"
"$test_dir/bluetooth-session"
xcrun swiftc -parse-as-library Bluetooth/Models.swift Bluetooth/GAIAProtocol.swift Bluetooth/HeadphoneController.swift tools/test-headphone-controller.swift -o "$test_dir/headphone-controller"
"$test_dir/headphone-controller"
xcrun swiftc -parse-as-library Bluetooth/DongleController.swift tools/test-dongle.swift -o "$test_dir/dongle"
"$test_dir/dongle"
xcrun swiftc -parse-as-library App/AudioOutputSwitcher.swift UI/Components.swift tools/test-audio-observation.swift -o "$test_dir/audio-observation"
"$test_dir/audio-observation"
printf 'All offline checks passed. Binaries are in %s\n' "$test_dir"

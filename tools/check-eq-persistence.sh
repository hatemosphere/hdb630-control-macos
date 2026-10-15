#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
check_dir=$(mktemp -d build/eq-persistence.XXXXXX)
xcrun swiftc -parse-as-library Bluetooth/Models.swift Bluetooth/GAIAProtocol.swift \
    Bluetooth/GAIACommandSession.swift Bluetooth/BluetoothManager.swift \
    tools/cli_eq_persistence.swift -import-objc-header HDB630Control-Bridging-Header.h \
    -o "$check_dir/eq-persistence"
"$check_dir/eq-persistence" "$@"

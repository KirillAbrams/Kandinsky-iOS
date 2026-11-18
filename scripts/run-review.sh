#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

runtime=com.apple.CoreSimulator.SimRuntime.iOS-26-3
device_type=com.apple.CoreSimulator.SimDeviceType.iPhone-17
target_file=DerivedData/review-simulator-id

if ! xcrun simctl list runtimes -j | /usr/bin/python3 -c '
import json, sys
runtime = sys.argv[1]
items = json.load(sys.stdin)["runtimes"]
sys.exit(not any(item["identifier"] == runtime and item["isAvailable"] for item in items))
' "$runtime"; then
    printf '%s\n' 'Добавь симулятор iOS 26.3 в Xcode → Settings → Components.' >&2
    exit 1
fi

target=
if [[ -s "$target_file" ]]; then
    target=$(cat "$target_file")
fi
if [[ -z "$target" ]] || ! xcrun simctl list devices -j | /usr/bin/python3 -c '
import json, sys
runtime, target = sys.argv[1:]
devices = json.load(sys.stdin)["devices"].get(runtime, [])
sys.exit(not any(item["udid"] == target and item["isAvailable"] for item in devices))
' "$runtime" "$target"; then
    target=$(xcrun simctl create 'Kandinsky Review iPhone 17' "$device_type" "$runtime")
    mkdir -p DerivedData
    printf '%s\n' "$target" > "$target_file"
fi

xcrun simctl bootstatus "$target" -b
open -a Simulator --args -CurrentDeviceUDID "$target"
xcodebuild -project ios/Kandinsky.xcodeproj -scheme Kandinsky -configuration Release \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData -quiet build
xcrun simctl install "$target" DerivedData/Build/Products/Release-iphonesimulator/Kandinsky.app
xcrun simctl launch "$target" dev.kirill.kandinsky.native

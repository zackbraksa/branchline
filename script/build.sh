#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

swift build --product Branchline
binary="$(swift build --show-bin-path)/Branchline"
sparkle=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
app="dist/Branchline.app"

python3 -B script/bundle.py --binary "$binary" --output "$app" --mode development --sparkle-framework "$sparkle"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
printf 'Built %s\n' "$app"

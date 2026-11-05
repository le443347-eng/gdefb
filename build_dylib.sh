#!/usr/bin/env bash
# Build VideoStarTool.dylib (iOS arm64) - chay tren macOS co Xcode
set -euo pipefail
NAME="VideoStarTool"; SRC="${NAME}.mm"; OUT="build"; MIN_IOS="${MIN_IOS:-13.0}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"; CXX="$(xcrun --sdk iphoneos -f clang++)"
mkdir -p "$OUT"
"$CXX" -arch arm64 -isysroot "$SDK" -miphoneos-version-min="$MIN_IOS" \
  -std=gnu++17 -fobjc-arc -fvisibility=hidden -O2 -I. \
  -Wno-unused-variable -Wno-unused-function -Wno-deprecated-declarations \
  -Wno-undeclared-selector -Wno-arc-performSelector-leaks \
  -dynamiclib -install_name "@executable_path/Frameworks/${NAME}.dylib" \
  -framework Foundation -framework UIKit -framework AVFoundation \
  -framework CoreMedia -framework CoreGraphics -framework QuartzCore -lobjc -lc++ \
  "$SRC" -o "$OUT/${NAME}.dylib"
strip -x "$OUT/${NAME}.dylib" || true
if command -v ldid >/dev/null 2>&1; then ldid -S "$OUT/${NAME}.dylib"
elif [[ -n "${CODESIGN_ID:-}" ]]; then codesign -f -s "$CODESIGN_ID" "$OUT/${NAME}.dylib"; fi
lipo -info "$OUT/${NAME}.dylib"; otool -L "$OUT/${NAME}.dylib"

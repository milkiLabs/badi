#!/usr/bin/env bash
# Build the Zig dynamic library and stage it where Flutter expects it.
# Usage: ./tool/build_zig.sh [--android] [--all]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/zig_lib"

build_host() {
  echo "==> zig build (host)"
  zig build
  ls -la "$ROOT/zig_lib/zig-out/lib/"
}

# Cross-compile one Android ABI. Zig ships its own android libc, no NDK needed.
build_android_abi() {
  local zig_target="$1"   # e.g. aarch64-linux-android
  local android_abi="$2"  # e.g. arm64-v8a
  echo "==> zig build -Dtarget=$zig_target (android $android_abi)"
  zig build -Dtarget="$zig_target" --prefix "$ROOT/zig_lib/zig-out-android/$android_abi"
  local src
  src="$(find "$ROOT/zig_lib/zig-out-android/$android_abi/lib" -name 'libzig_lib.so' | head -n 1)"
  local dst="$ROOT/android/app/src/main/jniLibs/$android_abi/libzig_lib.so"
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  echo "    staged -> $dst"
}

MODE="${1:---host}"
if [[ "$MODE" == "--host" ]]; then
  build_host
elif [[ "$MODE" == "--android" || "$MODE" == "--all" ]]; then
  build_android_abi aarch64-linux-android arm64-v8a
  build_android_abi arm-linux-androideabi armeabi-v7a
  build_android_abi x86_64-linux-android x86_64
  if [[ "$MODE" == "--all" ]]; then
    build_host
  fi
  echo "==> jniLibs content:"
  find "$ROOT/android/app/src/main/jniLibs" -type f | sort
else
  echo "Unknown arg: $MODE (expected --host, --android, --all)" >&2
  exit 1
fi

cat <<'EOF'

Next steps:
  host (linux desktop):  flutter run  (linux/CMakeLists.txt installs zig-out/lib/*.so into bundle/lib/)
  regenerate bindings:   dart run tool/ffigen.dart
  android device:        ./tool/build_zig.sh --android && flutter run
EOF

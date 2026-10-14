#!/usr/bin/env bash
# Build the Badi native library for the Linux desktop host.
# Usage: ./tool/build_zig.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/badi_lib"

echo "==> zig build (host)"
zig build
ls -la "$ROOT/badi_lib/zig-out/lib/"

cat <<'EOF'

Next steps:
  run:                   flutter run  (linux/CMakeLists.txt installs zig-out/lib/*.so into bundle/lib/)
  regenerate bindings:   dart run tool/ffigen.dart
EOF

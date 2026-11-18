#!/bin/zsh
# Builds the fuzz harness against Sources/Core and runs one target.
#   zsh Tools/fuzz/fuzz.sh <target> [iterations] [seed]
set -euo pipefail
cd "${0:A:h}/../.."
B=${BUILD_DIR:-build}
mkdir -p "$B"
swiftc -Onone -g -swift-version 5 -sdk "$(xcrun --show-sdk-path)" \
  Sources/Core/*.swift Tools/fuzz/main.swift Tools/fuzz/gn_helpers.swift -o "$B/strokebook-fuzz"
"$B/strokebook-fuzz" "${1:-codec-deep}" "${2:-1000}" "${3:-88172645463325252}"

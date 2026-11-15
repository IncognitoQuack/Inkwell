#!/bin/zsh
# Builds and runs the core test suite (no XCTest needed).
set -euo pipefail
cd "${0:A:h}"
B=${BUILD_DIR:-build}
mkdir -p "$B"
swiftc -O -swift-version 5 -sdk "$(xcrun --show-sdk-path)" \
  Sources/Core/*.swift Tests/main.swift -o "$B/inkwell-tests"
"$B/inkwell-tests"

#!/usr/bin/env bash
# Thin wrapper kept for any leftover callers; plugin hooks invoke the binary.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/target/release/herdr-sidebar-ensure" "$@"

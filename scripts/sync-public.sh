#!/usr/bin/env bash
# Copy install CDN assets into public/ before Pages deploy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLIC="$ROOT/public"

mkdir -p "$PUBLIC/lib"
cp "$ROOT/install.sh" "$ROOT/manifest.json" "$PUBLIC/"
cp "$ROOT/lib/"*.sh "$PUBLIC/lib/"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
rive CatalogInterface --once
swift run --package-path CatalogInterface/macOS \
    --scratch-path "$HOME/Library/Caches/RiveCatalogManager" \
    CatalogManager --root "$PWD" "$@"

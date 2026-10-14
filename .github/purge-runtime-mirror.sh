#!/usr/bin/env bash
# Phones read runtime/*.json from raw.githubusercontent.com and fall back to the jsDelivr
# copy (LiveSettingsService.swift, AppUpdate.swift). jsDelivr caches a branch for up to
# 12 hours; purging lets the fallback match main within minutes. Best effort: phones never
# accept an older settings revision, and the update switch only acts on App Store versions.
set -uo pipefail
repository="${GITHUB_REPOSITORY:-rio10255254/TaipeiBus}"
for name in settings.json app-update.json tuning.json; do
  curl -fsS --retry 3 "https://purge.jsdelivr.net/gh/${repository}@main/runtime/${name}" > /dev/null ||
    echo "::warning::jsDelivr purge failed for runtime/${name}; it refreshes within 12 hours."
done

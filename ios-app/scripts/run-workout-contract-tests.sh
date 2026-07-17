#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/open-bike-workout-contract-tests.XXXXXX")"
trap 'rm -rf "${OUT_DIR}"' EXIT
OUT="${OUT_DIR}/runner"

cd "${REPO_DIR}"

xcrun swiftc \
  -parse-as-library \
  -default-isolation MainActor \
  -o "${OUT}" \
  ios-app/BikeComputer/WorkoutShared/WorkoutMetricUnits.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutContract.swift \
  ios-app/BikeComputerTests/WorkoutContractTests.swift

"${OUT}"

# XIAO Map-Lite Go/No-Go Record

This record is intentionally measurement-first. Do not mark map-lite as enabled
by default until a real XIAO nRF52840 Round Display run fills in the evidence
below.

## Decision

- Decision: Pending hardware evidence
- Date:
- Firmware commit:
- Test operator:
- Hardware:
- microSD card:
- Map extract / `.fmb` source:
- Area / coordinates tested:

## Required Evidence

Capture serial logs from a real device after SD mount, explicit map-lite opt-in,
GPS-driven map block probe, route-page render, and a representative ride UI
update. Keep the raw log path with this record.

```text
MAPLITE ON
```

```sh
python3 xiao-nrf52840/tools/serial_log_check.py /tmp/xiao-map-lite.log \
  --profile map-lite-candidate
```

If the measured result is a no-go, replace the candidate profile with explicit
no-go evidence. The log must still show a probe and the measured decision label.

```sh
python3 xiao-nrf52840/tools/serial_log_check.py /tmp/xiao-map-lite.log \
  --require-map-probe \
  --require-map-sd \
  --require-map-found \
  --require-map-from-gps \
  --require-map-enabled \
  --require-map-decision too-slow \
  --fail-map-render-budget
```

Use `too-complex`, `no-data`, or `invalid` instead of `too-slow` when that is
the measured reason.

## Measurements

| Measurement | Required / Target | Observed |
| --- | --- | --- |
| Boot free heap | nonzero and recorded | |
| Minimum diagnostic free heap | nonzero and recorded | |
| `map_enabled` | `1` only after explicit `MAPLITE ON` opt-in | |
| `map_sd` | `1` when SD is expected | |
| `map_has_probe` / `map_probes` | probe observed | |
| `map_from_gps` | `1` for GPS-driven candidate evidence | |
| `map_found` | `1` for candidate evidence | |
| `map_decision` | `candidate`, or documented no-go reason | |
| `map_open_ms` | recorded | |
| `map_scan_ms` | <= 150 ms for candidate | |
| `map_renders` | >= 1 for candidate | |
| `map_render_valid` | `1` for candidate | |
| `map_render_ms` | <= 150 ms for candidate | |
| `map_render_budget` | `0` for candidate | |
| `map_render_segments` | >= 1 for candidate; recorded for no-go | |
| Route-page UI responsiveness | no visible stalls during ride screen changes | |

## Raw Diagnostic Snapshot

Paste the most relevant `Diagnostics:` line here:

```text

```

## Follow-Up

- If candidate: keep map-lite experimental until at least one outdoor ride
  confirms UI responsiveness under normal BLE/GPS traffic.
- If no-go: leave map-lite disabled/experimental and record the measured
  bottleneck before doing more implementation work.

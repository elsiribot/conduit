# Bandwidth Monitor: Session OS Traffic + Overhead %

**Date:** 2026-08-23
**Branch:** erics-conduit (debug fork)
**Extends:** `2026-08-22-bandwidth-monitor-live-design.md`

## Goal

Show how much OS-recorded traffic (TrafficStats) the app used *during this
session*, and derive an overhead percentage against the payload counters —
so the header answers "how many wire bytes did this session really cost,
and how much of that is framing/TLS/reconnect overhead".

## Design

### Baseline capture (Dart)

New helper `lib/utils/session_traffic.dart`:

- `SessionTraffic.read()` wraps `TrafficStatsReader.read()`. On the first
  successful read it stores the values as the session baseline; every call
  returns both the current absolute values and the session delta
  (`current − baseline`, per direction).
- The platform channel may not be registered yet at the very start of
  `main()`, so "first successful read wins" defines the session start —
  in practice within seconds of launch (10 s snapshot timer; 1 s screen
  ticks while the monitor is open).
- **Reboot guard:** TrafficStats resets on device reboot. If a current
  value is *smaller* than the baseline, re-baseline to the current values
  (session delta restarts from zero) instead of showing negatives.
- Baseline and helper are process-global statics; no persistence.

Callers switch from `TrafficStatsReader.read()` to `SessionTraffic.read()`:
the `main.dart` 10 s snapshot timer (so the baseline is set early even if
the monitor screen is never opened — absolute values still feed
`log_bandwidth_snapshot`, unchanged) and the bandwidth screen tick.

### Header changes (`lib/screens/bandwidth_screen.dart`)

- The "OS since boot" figures in the summary tile are replaced by session
  figures: `OS session: ↑ x ↓ y (+N% overhead)`.
  - `overhead = (os_session_total / payload_total − 1) × 100`, where
    `os_session_total = session rx + tx` and `payload_total` = sum of
    `bytesSent + bytesReceived` over all entries.
  - Show `—` instead of a percentage while `payload_total` is 0 or OS
    data / baseline is unavailable. A negative result (possible while the
    baseline postdates early API traffic) displays as computed — it is
    honest and self-corrects as the session accumulates.
- The live wire-rate in the "now" line is unchanged (deltas between
  consecutive samples don't care about the baseline).

### Out of scope

- Snapshot log lines stay as they are (absolute `os_rx`/`os_tx`); offline
  analysis already diffs consecutive lines.
- No persistence of the baseline across app restarts.

## Testing

- `flutter analyze` clean (no Dart test suite).
- On-device: fresh app start → monitor shows small OS session numbers that
  grow with traffic; overhead % plausible (tens of percent during active
  use, ballooning share while idle-connected); reboot guard not directly
  testable without a reboot.

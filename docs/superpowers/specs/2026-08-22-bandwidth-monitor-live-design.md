# Bandwidth Monitor: Live View + Federation Entry Point

**Date:** 2026-08-22
**Branch:** erics-conduit (debug fork)
**Extends:** `2026-08-22-bandwidth-monitor-design.md`

## Goal

1. Make the bandwidth monitor reachable from the federation screen.
2. Make it live: rows update continuously and current throughput is visible,
   so traffic behavior can be watched in real time.

## Decisions

- **Entry point:** a `chartBar` IconButton in `FederationScreen`'s app-bar
  actions (before the existing @ and contacts icons), pushing the same
  global `BandwidthScreen`. The Settings card stays. No federation
  filtering — the screen is always global.
- **Reactivity:** Dart-side polling inside the screen. A
  `Timer.periodic(Duration(seconds: 1))` calls `bandwidthStats()` and
  `TrafficStatsReader.read()` each tick and rebuilds via `setState`.
  Registry gathering is trivially cheap; uniform ticks give uniform rate
  windows and an idle app correctly decays to 0/s. No Rust changes, no
  codegen. (Rejected: a Rust-side `subscribe_*` stream — emit-on-change
  fights rate display and adds FRB plumbing for no visible gain.)

## Screen rework (`lib/screens/bandwidth_screen.dart`)

- Replace the one-shot `FutureBuilder` + `RefreshIndicator` (pull-to-refresh
  is obsolete) with timer-driven state:
  - `initState`: load guardian names once (they only change on
    join/leave), take the first sample immediately, start the 1 s timer.
  - Each tick stores the new sample alongside the previous one and its
    timestamp; `setState` rebuilds.
  - `dispose` cancels the timer.
- **Header "now" line** computed from the delta between the last two
  samples over their actual time spread: payload ↑/↓ bytes/s, requests/s,
  and OS wire bytes ↑/↓ per second when TrafficStats is available. When no
  previous sample exists yet, show the line with zeros or dashes.
- **Error handling:** a failed tick keeps the last good data on screen
  (optionally note nothing — next tick usually recovers). The full-screen
  error + Retry state only appears if no sample has ever succeeded.
- **Stable sort:** rows sort by total bytes descending with the label as
  tiebreak, so equal rows don't shuffle between ticks (fixes the deferred
  sort-stability finding).
- Everything else (sections, aggregation, formatting, styles) unchanged.

## Entry point (`lib/screens/federation_screen.dart`)

In the app-bar `actions`, add before the @ icon:

```dart
IconButton(
  icon: const Icon(PhosphorIconsRegular.chartBar, size: smallIconSize),
  onPressed: () => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => BandwidthScreen(clientFactory: widget.clientFactory),
    ),
  ),
),
```

## Testing

- `flutter analyze` clean (no Dart test suite in this project).
- On-device: open from the federation app bar, watch rows tick during a
  payment, confirm the now-line spikes and decays back to 0/s, confirm
  leaving the screen stops the timer (no rebuild churn).

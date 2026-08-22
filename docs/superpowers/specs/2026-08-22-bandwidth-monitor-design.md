# Bandwidth Monitor Design

**Date:** 2026-08-22
**Branch:** erics-conduit (debug fork, not for main)

## Goal

Measure how many API requests the app makes, how large they are, and how many
wire bytes they cost — attributable per RPC method, per guardian, and per
gateway. Two consumers:

1. **Periodic snapshot logging** into `conduit.log` for later analysis via the
   debug-export tar.
2. **A debug page** in the app for interactive drill-down.

Uses Prometheus counters via `fedimint_metrics::REGISTRY`, matching the
server-side convention.

## Key constraint: wire bytes

True per-request wire bytes (TLS records, websocket framing, HTTP headers,
QUIC/iroh overhead) are not observable at any reasonable hook point. Decision:

- **Per-request attribution** uses serialized JSON payload sizes (request
  params + response value), counted at the connector layer.
- **Ground truth** comes from Android `TrafficStats` per-UID rx/tx byte
  counts — exact wire bytes for the whole app, sampled OS-side.
- The gap between the two is itself a useful signal (framing/reconnect
  overhead).

Rejected: custom counting jsonrpsee transport + iroh instrumentation for real
per-request wire bytes — too complex, too large a vendored diff.

## Architecture

All guardian RPCs flow through `IGuardianConnection::request` and all gateway
HTTP calls through `IGatewayConnection::request` in the already-vendored
`rust/vendor/fedimint-connectors` crate. Connections are obtained via
`ConnectorRegistry::connect_guardian` / `connect_gateway` — the single seam
where instrumentation wrappers are applied, covering all transports (ws, wss,
iroh, tor, gateway http) including reconnects.

```
Flutter (Dart)                        Rust (conduit crate)              Rust (vendored fedimint-connectors)
--------------                        --------------------              -----------------------------------
10s Timer ── TrafficStats ──┐
                            ├──> log_bandwidth_snapshot(rx, tx) ──> tracing target conduit::bandwidth ──> conduit.log
Debug export (pre-tar) ─────┘
Bandwidth screen ──────────────> bandwidth_stats() ──> gather(REGISTRY) <── conduit_api_* counters <── Instrumented*Connection wrappers
```

## Components

### 1. Vendored crate: `fedimint-connectors/src/bandwidth.rs` + wrappers

Two counter families registered into `fedimint_metrics::REGISTRY` (same style
as the existing `metrics.rs`):

| Metric | Labels | Meaning |
|---|---|---|
| `conduit_api_requests_total` | `kind`, `url`, `method`, `result` | Request count. `kind` ∈ `guardian`/`gateway`; `result` ∈ `ok`/`error` |
| `conduit_api_payload_bytes_total` | `kind`, `url`, `method`, `direction` | Serialized JSON bytes. `direction` ∈ `sent`/`received` |

Label values:

- `url` — the guardian or gateway URL as passed to `connect_*` (pre-override
  resolution is fine; overrides are a test feature).
- `method` — guardians: same formatting as `ws.rs` (`method` or
  `module_{id}_{method}`); gateways: the HTTP route (e.g. `send_payment_v2`).
- Cardinality is bounded: a handful of guardians/gateways × dozens of methods.

Two wrapper types in the vendored crate:

- `InstrumentedGuardianConnection { inner: DynGuaridianConnection, url: SafeUrl }`
- `InstrumentedGatewayConnection { inner: DynGatewayConnection, url: SafeUrl }`

Each implements the corresponding trait by delegating to `inner`, counting
around the call: sent bytes = `serde_json::to_vec(&params).len()` (guardian:
the `ApiRequestErased` JSON; gateway: the payload `Value`, 0 if none);
received bytes = `serde_json::to_vec(&value).len()` on `Ok`, 0 on `Err`.
`IConnection` methods (`is_connected`, `await_disconnection`) delegate
untouched. Wrappers are applied at the end of
`ConnectorRegistry::connect_guardian` / `connect_gateway`.

Re-serialization costs a little CPU per request; payloads are small (KBs) and
this is a debug fork — acceptable.

### 2. App crate: `rust/src/bandwidth.rs`

Adds `fedimint-metrics = "0.11.0"` as a direct dependency (already in the
tree via the connectors crate — must resolve to the same version so the
`REGISTRY` global is shared).

Two FRB-exposed functions:

- `bandwidth_stats() -> BandwidthStats`
  - `BandwidthStats { since_epoch_ms: i64, entries: Vec<BandwidthEntry> }`
  - `BandwidthEntry { kind: String, url: String, method: String, requests: u64, errors: u64, bytes_sent: u64, bytes_received: u64 }`
  - Implementation: `REGISTRY.gather()`, filter the two `conduit_api_*`
    families, join on (kind, url, method). `since_epoch_ms` is the app-start
    time, recorded once when `init_logging` runs.
- `log_bandwidth_snapshot(os_rx_bytes: Option<i64>, os_tx_bytes: Option<i64>)`
  - Builds the same entries, plus OS byte counts, serializes to one compact
    JSON object and emits it at `info` level under target
    `conduit::bandwidth` (the existing `LOG_FILTER` passes info-level
    non-`fm` targets).
  - **Dedup guard:** keeps a hash of the previous snapshot's counter values
    (excluding timestamp); if neither counters nor OS bytes changed since the
    last emitted snapshot, emits nothing. With a 10 s cadence this keeps idle
    periods out of the log (~8 MB/day of identical lines otherwise).
  - Snapshot JSON shape:
    `{"ts": ..., "since": ..., "os_rx": ..., "os_tx": ..., "entries": [{"kind": "guardian", "url": "...", "method": "...", "reqs": N, "errs": N, "tx": N, "rx": N}, ...]}`

Counters are session-only (in-memory, reset on app restart); long-term
analysis diffs consecutive snapshot lines, which carry an app-start timestamp
to detect resets.

### 3. Android wire-byte ground truth

`MainActivity.kt` overrides `configureFlutterEngine` and registers a
MethodChannel `app.conduit.wallet.eric/traffic` with one method
`getTrafficStats` returning
`{rx: TrafficStats.getUidRxBytes(Process.myUid()), tx: getUidTxBytes(...)}`.
`TrafficStats` may return `UNSUPPORTED` (-1) on some devices — mapped to null.

Dart helper `lib/utils/traffic_stats.dart`: wraps the channel, returns
`null` on non-Android platforms or channel errors, so all consumers degrade
gracefully.

### 4. Dart snapshot driver

In `main.dart` (alongside app init, after `init_logging`): a
`Timer.periodic(Duration(seconds: 10))` that reads TrafficStats and calls
`log_bandwidth_snapshot`. The Rust-side dedup guard makes the tight cadence
safe. Timers don't fire while Android has the app suspended — fine, counters
are monotonic and analysis diffs whatever snapshots exist.

The debug-export flow additionally calls `log_bandwidth_snapshot` once,
before invoking `export_debug_archive`, so every tar ends with a fresh
snapshot.

### 5. Debug page: `lib/screens/bandwidth_screen.dart`

Entry: a new `SettingsCard` ("Bandwidth Monitor") in `base_screen.dart` next
to "Export Debug Data". The screen loads `bandwidth_stats()` +
TrafficStats once on open, with pull-to-refresh.

Layout (existing widget/style conventions):

- **Header**: time since app start; OS wire bytes rx/tx (when available);
  total payload bytes sent/received; total request count. The OS-vs-payload
  gap is the overhead indicator.
- **By RPC method**: entries aggregated over URLs, one row per method —
  requests, errors, sent/received bytes — sorted by total bytes descending.
- **By endpoint**: entries aggregated over methods, one row per guardian or
  gateway URL. Guardian URLs are mapped to guardian names via the federation
  config where available (the app knows the peer list); gateways are labeled
  as such.

Byte values human-formatted (KB/MB). No live streaming — a refresh-on-demand
debug page is enough.

## Error handling

- Metric registration uses the same `expect` convention as the existing
  vendored `metrics.rs` (process-fatal only on programmer error).
- `log_bandwidth_snapshot` and `bandwidth_stats` never fail: gather errors
  or serialization problems degrade to empty entries / skipped snapshot.
- MethodChannel failures → null OS bytes; snapshot still logged without them.

## Testing

- **Vendored crate:** unit test that a wrapped mock `IGuardianConnection`
  increments both counter families with the expected labels and byte counts,
  and counts an error result correctly.
- **App crate:** unit test for `bandwidth_stats()` gathering/joining, and for
  the snapshot dedup guard (second identical snapshot emits nothing; a
  counter bump re-enables emission).
- **Manual:** on-device — open the bandwidth page after a payment, verify
  guardian rows and `module_*` methods appear; export a tar and check
  `conduit::bandwidth` lines parse as JSON.

## Follow-ups (out of scope)

- **Web requests** (lnurl fetch, exchange rates): a counting `reqwest` helper
  in the app crate recording into the same registry with `kind=web`,
  `method=<host>` labels. Cheap once this lands.
- iOS wire-byte ground truth (no TrafficStats equivalent wired up).
- Mapping `module_{id}` to module kind names in the UI via client config.
- Upstreaming the connector counters to fedimint proper.

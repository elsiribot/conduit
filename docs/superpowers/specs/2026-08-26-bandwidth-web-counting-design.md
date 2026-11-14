# Bandwidth Monitor: kind=web Request Counting

**Date:** 2026-08-26
**Branch:** erics-conduit (debug fork)
**Extends:** `2026-08-22-bandwidth-monitor-design.md` (listed there as follow-up)

## Goal

Count the app's own web requests (exchange rates, lnurl) in the same
Prometheus families as guardian/gateway traffic, so the debug page and
snapshot lines show them and the OS-vs-payload overhead gap shrinks to
actual transport overhead.

## Design

### Recording helper (`rust/src/bandwidth.rs`)

```rust
pub(crate) fn count_web_request(host: &str, method: &str, sent: u64, received: Option<u64>)
```

increments the existing vendored-crate counters
(`fedimint_connectors::bandwidth::{API_REQUESTS_TOTAL, API_PAYLOAD_BYTES_TOTAL}`)
with `kind="web"`, `url=<scheme://host/>`, `method=<logical name>`;
`received: None` means the request failed (`result=error`, no received
bytes) — mirroring the vendored `record()` semantics.

### Call sites

- `rust/src/exchange.rs` (`fetch_exchange_rate`): read the body via
  `.bytes()` and parse with `serde_json::from_slice` so the exact body
  size is known. Labels: host `https://price-feed.dev.fedibtc.com/`,
  method `exchange_rate`. Count errors (fetch or parse) as error with 0
  received.
- `rust/src/lnurl.rs` (`lnurl_fetch_limits`, `lnurl_resolve`): HTTP lives
  inside `fedimint-lnurl`, so exact body sizes are not observable.
  Approximate: received = `serde_json::to_vec(&response)` of the parsed
  `PayResponse` / invoice response (both are `Serialize`), sent = 0
  (GETs). Host label parsed from the lnurl URL (`lnurl.0`) /
  `PayResponse.callback` via `url::Url` (scheme + host; fall back to
  `"unknown"` on parse failure). Methods: `lnurl_pay`, `lnurl_invoice`.
  Document the approximation in a comment.

### UI + docs

- `bandwidth_screen.dart`: `kind == 'web'` rows get the globe icon
  (`PhosphorIconsRegular.globe`); endpoint fallback label is the bare
  host (no "Gateway" prefix). No other UI change — aggregation, snapshot
  lines, and the overhead % pick the new kind up automatically.
- Update the bandwidth section of
  `.claude/skills/analyzing-debug-exports/SKILL.md`: `kind:
  guardian|gateway|web`, noting web rx for lnurl is approximate
  (re-serialized parsed response).

### Accepted trade-offs

- lnurl host labels are unbounded across payees — acceptable cardinality
  on a debug fork.
- lnurl byte counts are approximations (unknown/extra JSON fields and
  whitespace are lost); exchange-rate counts are exact.

## Testing

- Rust unit test in `rust/src/bandwidth.rs`: `count_web_request`
  increments both families with the expected labels for ok and error
  cases (unique host per test, existing lock conventions).
- `cargo test -p conduit --lib bandwidth`, `flutter analyze`, APK build.

# Bandwidth Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Count every guardian/gateway API request the app makes (count, method, endpoint, payload bytes) in Prometheus counters, log 10-second JSON snapshots into `conduit.log`, and add a debug page for drill-down, with Android `TrafficStats` as wire-byte ground truth.

**Architecture:** Instrumented wrapper types around the connections handed out by `ConnectorRegistry` in the already-vendored `rust/vendor/fedimint-connectors` crate record counters into `fedimint_metrics::REGISTRY`. The app crate gathers the registry for an FRB-exposed stats call and a snapshot-logging call driven by a Dart timer; a MethodChannel supplies OS-level rx/tx bytes. A new Flutter screen renders the drill-down.

**Tech Stack:** Rust (prometheus 0.14 via fedimint-metrics 0.11.1, flutter_rust_bridge 2.10), Flutter/Dart, Kotlin (MethodChannel).

**Spec:** `docs/superpowers/specs/2026-08-22-bandwidth-monitor-design.md`

## Global Constraints

- Branch `erics-conduit` (debug fork); commit style matches existing history (`feat:`, `fix:`, `docs:`, `build:`).
- The vendored crate diff must stay additive and self-contained (it gets dropped on the next fedimint bump).
- Metric families: `conduit_api_requests_total{kind,url,method,result}` and `conduit_api_payload_bytes_total{kind,url,method,direction}`. `kind` ∈ `guardian`/`gateway`, `result` ∈ `ok`/`error`, `direction` ∈ `sent`/`received`. NOTE: `REGISTRY` has namespace `fm`, so gathered family names are `fm_conduit_api_requests_total` / `fm_conduit_api_payload_bytes_total`.
- Snapshot log target: `conduit::bandwidth`, level `info` (passes the existing `LOG_FILTER` in `rust/src/logging.rs` which starts with `info,`).
- FRB-facing numeric fields use `i64` (project convention — see `msats as i64` usage in `rust/src/client.rs`).
- Rust commands run from `/home/user/projects/conduit/rust`; Flutter commands from `/home/user/projects/conduit`.
- After changing any FRB-exposed Rust API, regenerate bindings with `flutter_rust_bridge_codegen generate` (binary in `~/.cargo/bin`), run from the repo root.
- The project has no Flutter test suite; Dart verification is `flutter analyze` (must stay clean).

---

### Task 1: Counters and instrumented wrappers in the vendored connectors crate

**Files:**
- Create: `rust/vendor/fedimint-connectors/src/bandwidth.rs`
- Modify: `rust/vendor/fedimint-connectors/src/lib.rs` (add module + wrap at two call sites)

**Interfaces:**
- Consumes: existing traits `IGuardianConnection`, `IGatewayConnection`, `IConnection` and types `DynGuaridianConnection`, `DynGatewayConnection`, `ServerResult`, `ServerError` from `fedimint-connectors/src/lib.rs` (note the existing typo `DynGuaridianConnection` — use it as-is).
- Produces: `pub static API_REQUESTS_TOTAL: LazyLock<IntCounterVec>` and `pub static API_PAYLOAD_BYTES_TOTAL: LazyLock<IntCounterVec>` in `fedimint_connectors::bandwidth` (Task 2 reads these via `fedimint_metrics::REGISTRY.gather()` and the app-side test increments them directly). Wrapper types `InstrumentedGuardianConnection::new(inner, url: &SafeUrl)` and `InstrumentedGatewayConnection::new(inner, url: &SafeUrl)`.

- [ ] **Step 1: Write the failing tests**

Create `rust/vendor/fedimint-connectors/src/bandwidth.rs` with the test module only (implementation comes in Step 3 — for now add just the imports the tests need and a `todo!()`-free skeleton by defining nothing; the tests will fail to compile, which counts as the failing state for this step):

```rust
#[cfg(test)]
mod tests {
    use anyhow::anyhow;
    use async_trait::async_trait;
    use fedimint_core::module::{ApiMethod, ApiRequestErased};
    use fedimint_core::util::SafeUrl;
    use fedimint_core::{apply, async_trait_maybe_send};
    use serde_json::{Value, json};

    use super::*;
    use crate::{IConnection, IGuardianConnection, ServerError, ServerResult};

    #[derive(Debug)]
    struct MockGuardian {
        fail: bool,
    }

    #[apply(async_trait_maybe_send!)]
    impl IConnection for MockGuardian {
        fn is_connected(&self) -> bool {
            true
        }

        async fn await_disconnection(&self) {
            std::future::pending().await
        }
    }

    #[async_trait]
    impl IGuardianConnection for MockGuardian {
        async fn request(
            &self,
            _method: ApiMethod,
            _request: ApiRequestErased,
        ) -> ServerResult<Value> {
            if self.fail {
                Err(ServerError::ServerError(anyhow!("boom")))
            } else {
                Ok(json!({"answer": 42}))
            }
        }
    }

    fn test_url(name: &str) -> SafeUrl {
        SafeUrl::parse(&format!("wss://{name}.example.com/")).expect("valid url")
    }

    #[test]
    fn counts_ok_request_and_payload_bytes() {
        let url = test_url("count-ok");
        let conn = InstrumentedGuardianConnection::new(
            std::sync::Arc::new(MockGuardian { fail: false }),
            &url,
        );

        let request = ApiRequestErased::new(json!({"a": "b"}));
        let expected_sent = serde_json::to_vec(&request.to_json()).unwrap().len() as u64;
        let expected_received = serde_json::to_vec(&json!({"answer": 42})).unwrap().len() as u64;

        futures::executor::block_on(conn.request(
            ApiMethod::Core("session_count".to_string()),
            request,
        ))
        .expect("mock succeeds");

        let url_label = url.to_string();
        assert_eq!(
            API_REQUESTS_TOTAL
                .with_label_values(&["guardian", &url_label, "session_count", "ok"])
                .get(),
            1
        );
        assert_eq!(
            API_PAYLOAD_BYTES_TOTAL
                .with_label_values(&["guardian", &url_label, "session_count", "sent"])
                .get(),
            expected_sent
        );
        assert_eq!(
            API_PAYLOAD_BYTES_TOTAL
                .with_label_values(&["guardian", &url_label, "session_count", "received"])
                .get(),
            expected_received
        );
    }

    #[test]
    fn counts_error_request_without_received_bytes() {
        let url = test_url("count-err");
        let conn = InstrumentedGuardianConnection::new(
            std::sync::Arc::new(MockGuardian { fail: true }),
            &url,
        );

        futures::executor::block_on(conn.request(
            ApiMethod::Module(1, "await_receive".to_string()),
            ApiRequestErased::default(),
        ))
        .expect_err("mock fails");

        let url_label = url.to_string();
        assert_eq!(
            API_REQUESTS_TOTAL
                .with_label_values(&["guardian", &url_label, "module_1_await_receive", "error"])
                .get(),
            1
        );
        assert_eq!(
            API_PAYLOAD_BYTES_TOTAL
                .with_label_values(&["guardian", &url_label, "module_1_await_receive", "received"])
                .get(),
            0
        );
    }
}
```

Register the module in `rust/vendor/fedimint-connectors/src/lib.rs` — after line 1 (`pub mod error;`), the module list becomes:

```rust
pub mod bandwidth;
pub mod error;
pub mod http;
pub mod iroh;
pub mod metrics;
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/user/projects/conduit/rust && cargo test -p fedimint-connectors --lib bandwidth 2>&1 | tail -20`
Expected: COMPILE ERROR — `InstrumentedGuardianConnection`, `API_REQUESTS_TOTAL` etc. not found.

- [ ] **Step 3: Write the implementation**

Prepend to `rust/vendor/fedimint-connectors/src/bandwidth.rs` (above the test module):

```rust
//! Conduit-only instrumentation: counts every guardian/gateway API request
//! and its serialized JSON payload sizes into the shared prometheus
//! registry. Additive fork change; drop with the vendored crate on the
//! next fedimint bump.

use std::sync::{Arc, LazyLock};

use async_trait::async_trait;
use fedimint_core::module::{ApiMethod, ApiRequestErased};
use fedimint_core::util::SafeUrl;
use fedimint_core::{apply, async_trait_maybe_send};
use fedimint_metrics::prometheus::IntCounterVec;
use fedimint_metrics::{REGISTRY, opts, register_int_counter_vec_with_registry};
use reqwest::Method;
use serde_json::Value;

use crate::{
    DynGatewayConnection, DynGuaridianConnection, IConnection, IGatewayConnection,
    IGuardianConnection, ServerResult,
};

/// Total API requests made by the client.
///
/// Labels: `kind` = guardian|gateway, `url`, `method`, `result` = ok|error.
pub static API_REQUESTS_TOTAL: LazyLock<IntCounterVec> = LazyLock::new(|| {
    register_int_counter_vec_with_registry!(
        opts!(
            "conduit_api_requests_total",
            "Total API requests made by the client",
        ),
        &["kind", "url", "method", "result"],
        REGISTRY
    )
    .expect("metric registration should not fail")
});

/// Serialized JSON payload bytes exchanged with guardians/gateways.
///
/// Labels: `kind`, `url`, `method`, `direction` = sent|received. Excludes
/// transport framing (TLS, websocket, HTTP headers) — see the design doc.
pub static API_PAYLOAD_BYTES_TOTAL: LazyLock<IntCounterVec> = LazyLock::new(|| {
    register_int_counter_vec_with_registry!(
        opts!(
            "conduit_api_payload_bytes_total",
            "Serialized JSON payload bytes sent to / received from API endpoints",
        ),
        &["kind", "url", "method", "direction"],
        REGISTRY
    )
    .expect("metric registration should not fail")
});

/// Same formatting as the ws transport uses for the wire method name.
fn method_label(method: &ApiMethod) -> String {
    match method {
        ApiMethod::Core(method) => method.clone(),
        ApiMethod::Module(module_id, method) => format!("module_{module_id}_{method}"),
    }
}

fn json_size(value: &Value) -> u64 {
    serde_json::to_vec(value).map_or(0, |v| v.len() as u64)
}

fn record(kind: &str, url: &str, method: &str, sent: u64, result_ok: Option<u64>) {
    API_PAYLOAD_BYTES_TOTAL
        .with_label_values(&[kind, url, method, "sent"])
        .inc_by(sent);

    let result_label = if result_ok.is_some() { "ok" } else { "error" };
    API_REQUESTS_TOTAL
        .with_label_values(&[kind, url, method, result_label])
        .inc();

    if let Some(received) = result_ok {
        API_PAYLOAD_BYTES_TOTAL
            .with_label_values(&[kind, url, method, "received"])
            .inc_by(received);
    }
}

#[derive(Debug)]
pub struct InstrumentedGuardianConnection {
    inner: DynGuaridianConnection,
    url: String,
}

impl InstrumentedGuardianConnection {
    pub fn new(inner: DynGuaridianConnection, url: &SafeUrl) -> Self {
        Self {
            inner,
            url: url.to_string(),
        }
    }
}

#[apply(async_trait_maybe_send!)]
impl IConnection for InstrumentedGuardianConnection {
    fn is_connected(&self) -> bool {
        self.inner.is_connected()
    }

    async fn await_disconnection(&self) {
        self.inner.await_disconnection().await;
    }
}

#[async_trait]
impl IGuardianConnection for InstrumentedGuardianConnection {
    async fn request(&self, method: ApiMethod, request: ApiRequestErased) -> ServerResult<Value> {
        let method_label = method_label(&method);
        let sent = json_size(&request.to_json());

        let result = self.inner.request(method, request).await;

        record(
            "guardian",
            &self.url,
            &method_label,
            sent,
            result.as_ref().ok().map(json_size),
        );

        result
    }
}

#[derive(Debug)]
pub struct InstrumentedGatewayConnection {
    inner: DynGatewayConnection,
    url: String,
}

impl InstrumentedGatewayConnection {
    pub fn new(inner: DynGatewayConnection, url: &SafeUrl) -> Self {
        Self {
            inner,
            url: url.to_string(),
        }
    }
}

#[apply(async_trait_maybe_send!)]
impl IConnection for InstrumentedGatewayConnection {
    fn is_connected(&self) -> bool {
        self.inner.is_connected()
    }

    async fn await_disconnection(&self) {
        self.inner.await_disconnection().await;
    }
}

#[apply(async_trait_maybe_send!)]
impl IGatewayConnection for InstrumentedGatewayConnection {
    async fn request(
        &self,
        password: Option<String>,
        method: Method,
        route: &str,
        payload: Option<Value>,
    ) -> ServerResult<Value> {
        let sent = payload.as_ref().map_or(0, json_size);
        let route_label = route.to_string();

        let result = self.inner.request(password, method, route, payload).await;

        record(
            "gateway",
            &self.url,
            &route_label,
            sent,
            result.as_ref().ok().map(json_size),
        );

        result
    }
}

pub(crate) fn instrument_guardian(
    conn: DynGuaridianConnection,
    url: &SafeUrl,
) -> DynGuaridianConnection {
    Arc::new(InstrumentedGuardianConnection::new(conn, url))
}

pub(crate) fn instrument_gateway(conn: DynGatewayConnection, url: &SafeUrl) -> DynGatewayConnection {
    Arc::new(InstrumentedGatewayConnection::new(conn, url))
}
```

Note: `record`'s `result_ok` parameter is `Option<received_bytes>` — `Some` means the request succeeded. `json_size` is passed as a function to `.map(json_size)` for the guardian case (`&Value` arg) and `.map_or(0, json_size)` for payloads; both compile because `json_size` takes `&Value`.

Then hook the wrappers into `rust/vendor/fedimint-connectors/src/lib.rs`:

In `ConnectorRegistry::connect_guardian` (currently ~line 395), the tail of the function is:

```rust
        let conn = result.inspect_err(|err| {
            trace!(
                target: LOG_NET,
                %url,
                err = %err.fmt_compact(),
                "Connection failed"
            );
        })?;

        trace!(
            target: LOG_NET,
            %url,
            "Connection returned"
        );
        Ok(conn)
```

Change the last line to:

```rust
        Ok(crate::bandwidth::instrument_guardian(conn, url))
```

In `ConnectorRegistry::connect_gateway` (currently ~line 474), the function ends with:

```rust
        result
```

Change it to:

```rust
        Ok(crate::bandwidth::instrument_gateway(result?, url))
```

(`url` is in scope in both functions as the post-override `&SafeUrl`; connection overrides are a test-only feature, so labeling with the post-override URL is intended.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/user/projects/conduit/rust && cargo test -p fedimint-connectors --lib bandwidth 2>&1 | tail -10`
Expected: `test bandwidth::tests::counts_ok_request_and_payload_bytes ... ok`, `test bandwidth::tests::counts_error_request_without_received_bytes ... ok`, `test result: ok. 2 passed`

- [ ] **Step 5: Check the whole crate still compiles (wasm-independent paths)**

Run: `cd /home/user/projects/conduit/rust && cargo check -p fedimint-connectors 2>&1 | tail -5`
Expected: `Finished` with no errors (warnings about unused code are acceptable only if pre-existing).

- [ ] **Step 6: Commit**

```bash
cd /home/user/projects/conduit
git add rust/vendor/fedimint-connectors/src/bandwidth.rs rust/vendor/fedimint-connectors/src/lib.rs
git commit -m "feat: Count API requests and payload bytes in the vendored connectors"
```

---

### Task 2: App-side stats gathering and snapshot logging (`rust/src/bandwidth.rs`)

**Files:**
- Create: `rust/src/bandwidth.rs`
- Modify: `rust/Cargo.toml` (add `fedimint-metrics` dependency)
- Modify: `rust/src/lib.rs` (module + re-exports)
- Modify: `rust/src/logging.rs` (record app start)

**Interfaces:**
- Consumes: `fedimint_connectors::bandwidth::{API_REQUESTS_TOTAL, API_PAYLOAD_BYTES_TOTAL}` (test only), `fedimint_metrics::REGISTRY`.
- Produces (used by Dart in Tasks 5/6 after codegen):
  - `pub fn bandwidth_stats() -> BandwidthStats`
  - `pub fn log_bandwidth_snapshot(os_rx_bytes: Option<i64>, os_tx_bytes: Option<i64>)`
  - `pub struct BandwidthStats { pub since_epoch_ms: i64, pub entries: Vec<BandwidthEntry> }`
  - `pub struct BandwidthEntry { pub kind: String, pub url: String, pub method: String, pub requests: i64, pub errors: i64, pub bytes_sent: i64, pub bytes_received: i64 }`
  - `pub(crate) fn record_app_start()` (called from `init_logging`)

- [ ] **Step 1: Add the dependency**

In `rust/Cargo.toml`, `[dependencies]` section, after the line `fedimint-connectors = "0.11.0"`:

```toml
fedimint-metrics = "0.11.0"
```

(Resolves to 0.11.1 per the existing lockfile — same instance as the vendored crate uses, so the `REGISTRY` global is shared.)

- [ ] **Step 2: Write the failing tests**

Create `rust/src/bandwidth.rs` containing (tests only for now — the `use super::*` items don't exist yet):

```rust
#[cfg(test)]
mod tests {
    use fedimint_connectors::bandwidth::{API_PAYLOAD_BYTES_TOTAL, API_REQUESTS_TOTAL};

    use super::*;

    #[test]
    fn collects_entries_joined_across_families() {
        let url = "wss://collect.example.com/";

        API_REQUESTS_TOTAL
            .with_label_values(&["guardian", url, "session_count", "ok"])
            .inc_by(3);
        API_REQUESTS_TOTAL
            .with_label_values(&["guardian", url, "session_count", "error"])
            .inc();
        API_PAYLOAD_BYTES_TOTAL
            .with_label_values(&["guardian", url, "session_count", "sent"])
            .inc_by(120);
        API_PAYLOAD_BYTES_TOTAL
            .with_label_values(&["guardian", url, "session_count", "received"])
            .inc_by(4500);

        let entries = collect_entries();
        let entry = entries
            .iter()
            .find(|e| e.url == url && e.method == "session_count")
            .expect("entry present");

        assert_eq!(entry.kind, "guardian");
        assert_eq!(entry.requests, 4); // ok + error
        assert_eq!(entry.errors, 1);
        assert_eq!(entry.bytes_sent, 120);
        assert_eq!(entry.bytes_received, 4500);
    }

    #[test]
    fn snapshot_dedup_suppresses_unchanged_lines() {
        let url = "wss://dedup.example.com/";

        API_REQUESTS_TOTAL
            .with_label_values(&["guardian", url, "dedup_method", "ok"])
            .inc();

        let first = snapshot_line(Some(1000), Some(2000));
        assert!(first.is_some(), "first snapshot emits");

        let second = snapshot_line(Some(1000), Some(2000));
        assert!(second.is_none(), "unchanged snapshot suppressed");

        API_REQUESTS_TOTAL
            .with_label_values(&["guardian", url, "dedup_method", "ok"])
            .inc();

        let third = snapshot_line(Some(1000), Some(2000));
        assert!(third.is_some(), "counter bump re-enables emission");

        let fourth = snapshot_line(Some(1000), Some(9000));
        assert!(fourth.is_some(), "os byte change re-enables emission");
    }

    #[test]
    fn snapshot_line_is_valid_json_with_expected_shape() {
        API_REQUESTS_TOTAL
            .with_label_values(&[
                "guardian",
                "wss://shape.example.com/",
                "shape_method",
                "ok",
            ])
            .inc();

        let line = snapshot_line(Some(42), None).expect("changed counters emit");
        let value: serde_json::Value = serde_json::from_str(&line).expect("valid json");

        assert!(value["ts"].is_i64());
        assert!(value["since"].is_i64());
        assert_eq!(value["os_rx"], 42);
        assert!(value["os_tx"].is_null());
        assert!(value["entries"].is_array());
        let entry = value["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|e| e["method"] == "shape_method")
            .expect("entry present");
        assert_eq!(entry["kind"], "guardian");
        assert!(entry["reqs"].as_i64().unwrap() >= 1);
    }
}
```

Note: these tests share global counter state with each other (and run in one process), which is why each uses unique URLs/methods. `snapshot_dedup_suppresses_unchanged_lines` and the other snapshot test both mutate `LAST_SNAPSHOT_HASH`; the assertions only rely on "changed since last emitted" semantics, which hold regardless of interleaving because each test bumps a counter of its own right before asserting `is_some()` — except the plain `second` assertion, which relies on nothing else running between the two calls. To make that robust, serialize the two snapshot tests with a shared lock: add at the top of the test module:

```rust
    static SNAPSHOT_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
```

and take `let _guard = SNAPSHOT_TEST_LOCK.lock().unwrap();` as the first line of both `snapshot_dedup_suppresses_unchanged_lines` and `snapshot_line_is_valid_json_with_expected_shape`.

Also register the module in `rust/src/lib.rs` — the module list at the top becomes:

```rust
mod bandwidth;
mod client;
mod currency;
mod db;
mod events;
mod exchange;
mod factory;
mod fountain;
mod frb_generated;
mod lnurl;
mod logging;
```

and add to the re-export block (after the `pub use factory::...` line):

```rust
pub use bandwidth::{BandwidthEntry, BandwidthStats, bandwidth_stats, log_bandwidth_snapshot};
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd /home/user/projects/conduit/rust && cargo test -p conduit --lib bandwidth 2>&1 | tail -10`
Expected: COMPILE ERROR — `collect_entries`, `snapshot_line` not found.

- [ ] **Step 4: Write the implementation**

Prepend to `rust/src/bandwidth.rs` (above the test module):

```rust
//! Session bandwidth statistics: gathers the prometheus counters recorded
//! by the vendored connectors crate for the debug page, and emits periodic
//! JSON snapshot lines into the log for offline analysis.

use std::collections::BTreeMap;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use flutter_rust_bridge::frb;
use serde::Serialize;

const REQUESTS_FAMILY: &str = "fm_conduit_api_requests_total";
const PAYLOAD_FAMILY: &str = "fm_conduit_api_payload_bytes_total";

static APP_START_MS: OnceLock<i64> = OnceLock::new();
static LAST_SNAPSHOT_HASH: Mutex<Option<u64>> = Mutex::new(None);

/// Called once from `init_logging` so `since_epoch_ms` reflects app start.
pub(crate) fn record_app_start() {
    let _ = APP_START_MS.set(now_ms());
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

fn app_start_ms() -> i64 {
    APP_START_MS.get().copied().unwrap_or_else(now_ms)
}

#[frb]
pub struct BandwidthStats {
    pub since_epoch_ms: i64,
    pub entries: Vec<BandwidthEntry>,
}

/// One (kind, url, method) row of session counters. Serialized field names
/// are kept short because these appear in every snapshot log line.
#[frb]
#[derive(Clone, Hash, Serialize)]
pub struct BandwidthEntry {
    pub kind: String,
    pub url: String,
    pub method: String,
    #[serde(rename = "reqs")]
    pub requests: i64,
    #[serde(rename = "errs")]
    pub errors: i64,
    #[serde(rename = "tx")]
    pub bytes_sent: i64,
    #[serde(rename = "rx")]
    pub bytes_received: i64,
}

/// Gather the two `conduit_api_*` families from the shared registry and
/// join them on (kind, url, method).
fn collect_entries() -> Vec<BandwidthEntry> {
    let mut map: BTreeMap<(String, String, String), BandwidthEntry> = BTreeMap::new();

    for family in fedimint_metrics::REGISTRY.gather() {
        let family_name = family.name();
        if family_name != REQUESTS_FAMILY && family_name != PAYLOAD_FAMILY {
            continue;
        }

        for metric in family.get_metric() {
            let mut kind = String::new();
            let mut url = String::new();
            let mut method = String::new();
            let mut result = String::new();
            let mut direction = String::new();

            for label in metric.get_label() {
                match label.name() {
                    "kind" => kind = label.value().to_string(),
                    "url" => url = label.value().to_string(),
                    "method" => method = label.value().to_string(),
                    "result" => result = label.value().to_string(),
                    "direction" => direction = label.value().to_string(),
                    _ => {}
                }
            }

            let value = metric.get_counter().value() as i64;

            let entry = map
                .entry((kind.clone(), url.clone(), method.clone()))
                .or_insert_with(|| BandwidthEntry {
                    kind,
                    url,
                    method,
                    requests: 0,
                    errors: 0,
                    bytes_sent: 0,
                    bytes_received: 0,
                });

            if family_name == REQUESTS_FAMILY {
                entry.requests += value;
                if result == "error" {
                    entry.errors += value;
                }
            } else if direction == "sent" {
                entry.bytes_sent += value;
            } else if direction == "received" {
                entry.bytes_received += value;
            }
        }
    }

    map.into_values().collect()
}

#[derive(Serialize)]
struct Snapshot<'a> {
    ts: i64,
    since: i64,
    os_rx: Option<i64>,
    os_tx: Option<i64>,
    entries: &'a [BandwidthEntry],
}

/// Build the snapshot JSON line, or `None` if nothing changed since the
/// last emitted snapshot (keeps an idle app from flooding the log at the
/// 10s cadence).
fn snapshot_line(os_rx: Option<i64>, os_tx: Option<i64>) -> Option<String> {
    let entries = collect_entries();

    let mut hasher = DefaultHasher::new();
    entries.hash(&mut hasher);
    os_rx.hash(&mut hasher);
    os_tx.hash(&mut hasher);
    let hash = hasher.finish();

    {
        let mut last = LAST_SNAPSHOT_HASH.lock().expect("poisoned");
        if *last == Some(hash) {
            return None;
        }
        *last = Some(hash);
    }

    let snapshot = Snapshot {
        ts: now_ms(),
        since: app_start_ms(),
        os_rx,
        os_tx,
        entries: &entries,
    };

    serde_json::to_string(&snapshot).ok()
}

#[frb]
pub fn bandwidth_stats() -> BandwidthStats {
    BandwidthStats {
        since_epoch_ms: app_start_ms(),
        entries: collect_entries(),
    }
}

#[frb]
pub fn log_bandwidth_snapshot(os_rx_bytes: Option<i64>, os_tx_bytes: Option<i64>) {
    if let Some(line) = snapshot_line(os_rx_bytes, os_tx_bytes) {
        tracing::info!(target: "conduit::bandwidth", "{line}");
    }
}
```

In `rust/src/logging.rs`, inside `init_logging`, directly after the line `tracing::info!(target: "conduit", "file logging initialized");`:

```rust
    crate::bandwidth::record_app_start();
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /home/user/projects/conduit/rust && cargo test -p conduit --lib bandwidth 2>&1 | tail -10`
Expected: 3 tests pass (`collects_entries_joined_across_families`, `snapshot_dedup_suppresses_unchanged_lines`, `snapshot_line_is_valid_json_with_expected_shape`).

- [ ] **Step 6: Verify the full crate still checks**

Run: `cd /home/user/projects/conduit/rust && cargo check -p conduit 2>&1 | tail -5`
Expected: `Finished` with no errors.

- [ ] **Step 7: Commit**

```bash
cd /home/user/projects/conduit
git add rust/Cargo.toml rust/Cargo.lock rust/src/bandwidth.rs rust/src/lib.rs rust/src/logging.rs
git commit -m "feat: Gather bandwidth stats and log deduplicated JSON snapshots"
```

---

### Task 3: Guardian name mapping + FRB binding regeneration

**Files:**
- Modify: `rust/src/factory.rs` (add `guardian_names`)
- Regenerate: `lib/bridge_generated.dart/` (via codegen)

**Interfaces:**
- Consumes: `ClientConfigPrefix` DB prefix and `ClientConfig.global.api_endpoints` (`BTreeMap<PeerId, PeerUrl { url: SafeUrl, name: String }>`) — same pattern as `list_federations` at `rust/src/factory.rs:352`.
- Produces: `pub async fn guardian_names(&self) -> Vec<(String, String)>` on `ConduitClientFactory` — list of `(url, name)` pairs across all saved federation configs. URL strings are `SafeUrl::to_string()`, matching the counter labels exactly. Dart side (Task 6): `clientFactory.guardianNames()` returning `List<(String, String)>`.

- [ ] **Step 1: Implement `guardian_names`**

In `rust/src/factory.rs`, add after the `list_federations` method (after its closing brace, ~line 361):

```rust
    /// (url, guardian name) pairs across all saved federation configs,
    /// for labeling bandwidth counters on the debug page. URLs are
    /// formatted exactly like the counter labels (`SafeUrl::to_string`).
    #[frb]
    pub async fn guardian_names(&self) -> Vec<(String, String)> {
        self.db
            .begin_transaction_nc()
            .await
            .find_by_prefix(&ClientConfigPrefix)
            .await
            .map(|(_, config)| {
                config
                    .global
                    .api_endpoints
                    .into_values()
                    .map(|peer| (peer.url.to_string(), peer.name))
                    .collect::<Vec<_>>()
            })
            .concat()
            .await
    }
```

(`.concat()` is a `StreamExt` combinator flattening `Vec<Vec<_>>`; `futures_util::StreamExt` is already imported in factory.rs. If `concat` is not available on the stream type, use the fallback below.)

Fallback implementation with the same signature:

```rust
    #[frb]
    pub async fn guardian_names(&self) -> Vec<(String, String)> {
        let configs: Vec<ClientConfig> = self
            .db
            .begin_transaction_nc()
            .await
            .find_by_prefix(&ClientConfigPrefix)
            .await
            .map(|(_, config)| config)
            .collect()
            .await;

        configs
            .into_iter()
            .flat_map(|config| {
                config
                    .global
                    .api_endpoints
                    .into_values()
                    .map(|peer| (peer.url.to_string(), peer.name))
            })
            .collect()
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `cd /home/user/projects/conduit/rust && cargo check -p conduit 2>&1 | tail -5`
Expected: `Finished` with no errors.

- [ ] **Step 3: Regenerate FRB bindings**

Run: `cd /home/user/projects/conduit && ~/.cargo/bin/flutter_rust_bridge_codegen generate`
Expected: exits 0; `lib/bridge_generated.dart/` now contains a `bandwidth.dart` with `bandwidthStats()` and `logBandwidthSnapshot(...)`, and `factory.dart` gains `guardianNames()`.

- [ ] **Step 4: Verify the Dart side analyzes**

Run: `cd /home/user/projects/conduit && flutter analyze 2>&1 | tail -5`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
cd /home/user/projects/conduit
git add rust/src/factory.rs lib/bridge_generated.dart
git commit -m "feat: Expose bandwidth stats and guardian names over the bridge"
```

---

### Task 4: Android TrafficStats MethodChannel + Dart reader

**Files:**
- Modify: `android/app/src/main/kotlin/app/conduit/wallet/MainActivity.kt`
- Create: `lib/utils/traffic_stats.dart`

**Interfaces:**
- Produces: Dart `TrafficStatsReader.read() -> Future<({int rx, int tx})?>` — `null` on non-Android, channel failure, or `TrafficStats.UNSUPPORTED` (-1). Used by Tasks 5 and 6.

- [ ] **Step 1: Replace MainActivity with the MethodChannel version**

`android/app/src/main/kotlin/app/conduit/wallet/MainActivity.kt` becomes:

```kotlin
package app.conduit.wallet

import android.net.TrafficStats
import android.os.Process
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.conduit.wallet.eric/traffic",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getTrafficStats" -> {
                    val uid = Process.myUid()
                    result.success(
                        mapOf(
                            "rx" to TrafficStats.getUidRxBytes(uid),
                            "tx" to TrafficStats.getUidTxBytes(uid),
                        )
                    )
                }
                else -> result.notImplemented()
            }
        }
    }
}
```

- [ ] **Step 2: Create the Dart reader**

Create `lib/utils/traffic_stats.dart`:

```dart
import 'dart:io';
import 'package:flutter/services.dart';

/// Reads the app's own cumulative wire bytes (rx/tx since device boot) from
/// Android's per-UID TrafficStats. Returns null wherever the numbers are
/// unavailable so callers degrade gracefully.
class TrafficStatsReader {
  static const _channel = MethodChannel('app.conduit.wallet.eric/traffic');

  static Future<({int rx, int tx})?> read() async {
    if (!Platform.isAndroid) return null;

    try {
      final stats = await _channel.invokeMapMethod<String, int>(
        'getTrafficStats',
      );

      final rx = stats?['rx'];
      final tx = stats?['tx'];

      // TrafficStats.UNSUPPORTED is -1.
      if (rx == null || tx == null || rx < 0 || tx < 0) return null;

      return (rx: rx, tx: tx);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
```

- [ ] **Step 3: Verify analysis passes**

Run: `cd /home/user/projects/conduit && flutter analyze 2>&1 | tail -5`
Expected: `No issues found!` (Kotlin compiles only during the APK build — covered by Task 7.)

- [ ] **Step 4: Commit**

```bash
cd /home/user/projects/conduit
git add android/app/src/main/kotlin/app/conduit/wallet/MainActivity.kt lib/utils/traffic_stats.dart
git commit -m "feat: Read per-app wire bytes via an Android TrafficStats channel"
```

---

### Task 5: Dart snapshot driver (10 s timer + pre-export snapshot)

**Files:**
- Modify: `lib/main.dart` (timer)
- Modify: `lib/screens/base_screen.dart` (pre-export snapshot in `_handleDebugExportTap`)

**Interfaces:**
- Consumes: `logBandwidthSnapshot` from `package:conduit/bridge_generated.dart/bandwidth.dart` (Task 3) and `TrafficStatsReader` (Task 4). NOTE: check the generated signature in `lib/bridge_generated.dart/bandwidth.dart` for the exact parameter names/shape (FRB 2.10 generates named parameters `osRxBytes`/`osTxBytes` of type `int?`; adjust the calls if the generated code differs).

- [ ] **Step 1: Add the periodic timer to main.dart**

In `lib/main.dart`, add imports:

```dart
import 'dart:async';
import 'package:conduit/bridge_generated.dart/bandwidth.dart';
import 'package:conduit/utils/traffic_stats.dart';
```

In `main()`, directly after the `try { await initLogging(...) } catch ... }` block:

```dart
  // Bandwidth snapshot logging: cheap no-op inside Rust when nothing
  // changed, so the tight cadence is safe. See the bandwidth-monitor spec.
  Timer.periodic(const Duration(seconds: 10), (_) async {
    final traffic = await TrafficStatsReader.read();
    try {
      await logBandwidthSnapshot(
        osRxBytes: traffic?.rx,
        osTxBytes: traffic?.tx,
      );
    } catch (_) {
      // Logging must never break the app.
    }
  });
```

- [ ] **Step 2: Snapshot before debug export**

In `lib/screens/base_screen.dart`, add the same two imports (`bandwidth.dart`, `traffic_stats.dart`) to the import block, then in `_handleDebugExportTap`, inside the `try`, before the `exportDebugArchive` call:

```dart
      // Make sure the exported log ends with a fresh bandwidth snapshot.
      final traffic = await TrafficStatsReader.read();
      await logBandwidthSnapshot(
        osRxBytes: traffic?.rx,
        osTxBytes: traffic?.tx,
      );
```

- [ ] **Step 3: Verify analysis passes**

Run: `cd /home/user/projects/conduit && flutter analyze 2>&1 | tail -5`
Expected: `No issues found!`

- [ ] **Step 4: Commit**

```bash
cd /home/user/projects/conduit
git add lib/main.dart lib/screens/base_screen.dart
git commit -m "feat: Drive 10s bandwidth snapshots and snapshot before export"
```

---

### Task 6: Bandwidth debug screen + settings entry

**Files:**
- Create: `lib/screens/bandwidth_screen.dart`
- Modify: `lib/screens/base_screen.dart` (settings card + navigation)

**Interfaces:**
- Consumes: `bandwidthStats()` → `BandwidthStats { sinceEpochMs: int, entries: List<BandwidthEntry> }` with `BandwidthEntry { kind, url, method: String, requests, errors, bytesSent, bytesReceived: int }` (from `lib/bridge_generated.dart/bandwidth.dart`); `clientFactory.guardianNames()` → `List<(String, String)>`; `TrafficStatsReader.read()`. Reuses widgets `SectionHeader`, `BorderedList`, `BleedColumn`, `IconChip`, `SettingsCard` and styles `mediumStyle`, `smallStyle`, `listTilePadding` from `lib/utils/styles.dart` — follow `lib/screens/connection_status_screen.dart` as the visual reference.

- [ ] **Step 1: Create the screen**

Create `lib/screens/bandwidth_screen.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:conduit/bridge_generated.dart/bandwidth.dart';
import 'package:conduit/bridge_generated.dart/factory.dart';
import 'package:conduit/utils/styles.dart';
import 'package:conduit/utils/traffic_stats.dart';
import 'package:conduit/widgets/bleed_column_widget.dart';
import 'package:conduit/widgets/bordered_list_widget.dart';
import 'package:conduit/widgets/icon_chip_widget.dart';
import 'package:conduit/widgets/section_header_widget.dart';

class BandwidthScreen extends StatefulWidget {
  final ConduitClientFactory clientFactory;

  const BandwidthScreen({super.key, required this.clientFactory});

  @override
  State<BandwidthScreen> createState() => _BandwidthScreenState();
}

class _BandwidthData {
  final BandwidthStats stats;
  final Map<String, String> guardianNames;
  final ({int rx, int tx})? traffic;

  _BandwidthData(this.stats, this.guardianNames, this.traffic);
}

/// One aggregated row (either per method or per endpoint).
class _Row {
  final String label;
  final String kind;
  int requests = 0;
  int errors = 0;
  int bytesSent = 0;
  int bytesReceived = 0;

  _Row(this.label, this.kind);

  int get totalBytes => bytesSent + bytesReceived;
}

class _BandwidthScreenState extends State<BandwidthScreen> {
  late Future<_BandwidthData> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<_BandwidthData> _load() async {
    final stats = await bandwidthStats();
    final names = await widget.clientFactory.guardianNames();
    final traffic = await TrafficStatsReader.read();

    return _BandwidthData(stats, Map.fromEntries(
      names.map((pair) => MapEntry(pair.$1, pair.$2)),
    ), traffic);
  }

  Future<void> _refresh() async {
    final data = _load();
    setState(() => _data = data);
    await data;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bandwidth')),
      body: FutureBuilder<_BandwidthData>(
        future: _data,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          return RefreshIndicator(
            onRefresh: _refresh,
            child: _buildContent(snapshot.data!),
          );
        },
      ),
    );
  }

  Widget _buildContent(_BandwidthData data) {
    final entries = data.stats.entries;

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 32),
      child: BleedColumn(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Session'),
          BorderedList.column(children: [_buildSummaryTile(data)]),
          const SizedBox(height: 16),
          const SectionHeader(title: 'By RPC Method'),
          BorderedList.column(
            children: [
              for (final row in _aggregate(
                entries,
                (e) => '${e.kind}:${e.method}',
                (e) => e.method,
              ))
                _buildRowTile(row),
            ],
          ),
          const SizedBox(height: 16),
          const SectionHeader(title: 'By Endpoint'),
          BorderedList.column(
            children: [
              for (final row in _aggregate(
                entries,
                (e) => e.url,
                (e) => data.guardianNames[e.url] ??
                    (e.kind == 'gateway' ? 'Gateway ${e.url}' : e.url),
              ))
                _buildRowTile(row),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryTile(_BandwidthData data) {
    final entries = data.stats.entries;
    final requests = entries.fold(0, (sum, e) => sum + e.requests);
    final sent = entries.fold(0, (sum, e) => sum + e.bytesSent);
    final received = entries.fold(0, (sum, e) => sum + e.bytesReceived);
    final since = DateTime.fromMillisecondsSinceEpoch(data.stats.sinceEpochMs);
    final uptime = DateTime.now().difference(since);

    final traffic = data.traffic;
    final osLine = traffic == null
        ? 'OS wire bytes unavailable'
        : 'OS since boot: ↑ ${_formatBytes(traffic.tx)} ↓ ${_formatBytes(traffic.rx)}';

    return ListTile(
      contentPadding: listTilePadding,
      leading: const IconChip(icon: PhosphorIconsRegular.chartBar),
      title: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$requests requests · ↑ ${_formatBytes(sent)} ↓ ${_formatBytes(received)}',
            style: mediumStyle,
          ),
          Text(
            'Session ${_formatDuration(uptime)} · $osLine',
            style: smallStyle.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRowTile(_Row row) {
    return ListTile(
      contentPadding: listTilePadding,
      leading: IconChip(
        icon: row.kind == 'gateway'
            ? PhosphorIconsRegular.lightning
            : PhosphorIconsRegular.hardDrives,
      ),
      title: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            row.label,
            style: mediumStyle,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            '${row.requests} reqs'
            '${row.errors > 0 ? ' · ${row.errors} errs' : ''}'
            ' · ↑ ${_formatBytes(row.bytesSent)}'
            ' ↓ ${_formatBytes(row.bytesReceived)}',
            style: smallStyle.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// Aggregate entries by [key], label rows via [label], sort by total
  /// bytes descending.
  List<_Row> _aggregate(
    List<BandwidthEntry> entries,
    String Function(BandwidthEntry) key,
    String Function(BandwidthEntry) label,
  ) {
    final rows = <String, _Row>{};

    for (final entry in entries) {
      final row = rows.putIfAbsent(
        key(entry),
        () => _Row(label(entry), entry.kind),
      );
      row.requests += entry.requests;
      row.errors += entry.errors;
      row.bytesSent += entry.bytesSent;
      row.bytesReceived += entry.bytesReceived;
    }

    final sorted = rows.values.toList()
      ..sort((a, b) => b.totalBytes.compareTo(a.totalBytes));
    return sorted;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1000) return '$bytes B';
    if (bytes < 1000000) return '${(bytes / 1000).toStringAsFixed(1)} kB';
    if (bytes < 1000000000) {
      return '${(bytes / 1000000).toStringAsFixed(2)} MB';
    }
    return '${(bytes / 1000000000).toStringAsFixed(2)} GB';
  }

  String _formatDuration(Duration duration) {
    if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes % 60}m';
    }
    if (duration.inMinutes > 0) {
      return '${duration.inMinutes}m ${duration.inSeconds % 60}s';
    }
    return '${duration.inSeconds}s';
  }
}
```

NOTE for the implementer: `BandwidthEntry` field types in generated Dart may be `int` (from `i64`). If `fold` complains about types, annotate the accumulators (`fold<int>(0, ...)`). If `guardianNames()` returns `List<(String, String)>` the `pair.$1/pair.$2` accessors are correct; check the generated `factory.dart` if analysis fails.

- [ ] **Step 2: Add the settings card**

In `lib/screens/base_screen.dart`:

Add import:

```dart
import 'package:conduit/screens/bandwidth_screen.dart';
```

In the settings `BorderedList.column` children (currently `_buildSeedPhraseCard(), _buildCurrencyCard(), _buildDebugExportCard()`), insert before `_buildDebugExportCard()`:

```dart
              _buildBandwidthCard(),
```

Add the builder methods next to `_buildDebugExportCard`:

```dart
  Widget _buildBandwidthCard() {
    return SettingsCard(
      icon: PhosphorIconsRegular.chartBar,
      title: 'Bandwidth Monitor',
      subtitle: 'API requests and traffic',
      onTap: _handleBandwidthTap,
    );
  }

  void _handleBandwidthTap() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BandwidthScreen(clientFactory: widget.clientFactory),
      ),
    );
  }
```

- [ ] **Step 3: Verify analysis passes**

Run: `cd /home/user/projects/conduit && flutter analyze 2>&1 | tail -5`
Expected: `No issues found!`

- [ ] **Step 4: Commit**

```bash
cd /home/user/projects/conduit
git add lib/screens/bandwidth_screen.dart lib/screens/base_screen.dart
git commit -m "feat: Add the bandwidth monitor debug screen"
```

---

### Task 7: Full verification + on-device checklist

**Files:** none (verification only)

- [ ] **Step 1: Run all Rust tests**

Run: `cd /home/user/projects/conduit/rust && cargo test -p fedimint-connectors --lib && cargo test -p conduit --lib 2>&1 | tail -10`
Expected: all tests pass, including the 5 new bandwidth tests.

- [ ] **Step 2: Full analysis**

Run: `cd /home/user/projects/conduit && flutter analyze 2>&1 | tail -3`
Expected: `No issues found!`

- [ ] **Step 3: Build the APK (compiles Kotlin + full Rust for Android)**

Run: `cd /home/user/projects/conduit && ./build-android-nix.sh 2>&1 | tail -5`
Expected: build succeeds, APK produced. (This is the only step that compiles `MainActivity.kt` — do not skip it.)

- [ ] **Step 4: Manual on-device checklist (user or emulator via the running-local-android skill)**

1. Install and open the app; wait ~1 min with a federation joined.
2. Settings → Bandwidth Monitor: guardian rows appear with plausible request counts; `module_*` methods visible; OS wire bytes shown in the header.
3. Make a small LN payment; refresh the page; gateway rows appear.
4. Export Debug Data; untar; `grep 'conduit::bandwidth' logs/conduit-*.log | tail -1` — the line's JSON parses and includes `os_rx`/`os_tx` and entries.
5. Leave the app idle 1 min; export again; confirm consecutive identical snapshots were suppressed (no back-to-back duplicate lines).

- [ ] **Step 5: Report results to the user before claiming completion** (superpowers:verification-before-completion)

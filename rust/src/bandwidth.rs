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

#[cfg(test)]
mod tests {
    use fedimint_connectors::bandwidth::{API_PAYLOAD_BYTES_TOTAL, API_REQUESTS_TOTAL};

    use super::*;

    static SNAPSHOT_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[test]
    fn collects_entries_joined_across_families() {
        let _guard = SNAPSHOT_TEST_LOCK.lock().unwrap();
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
        let _guard = SNAPSHOT_TEST_LOCK.lock().unwrap();
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
        let _guard = SNAPSHOT_TEST_LOCK.lock().unwrap();
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

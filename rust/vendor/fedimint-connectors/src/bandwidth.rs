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

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde::Deserialize;
use tokio::sync::Mutex;

#[derive(Deserialize)]
struct FediPriceResponse {
    prices: BTreeMap<String, ExchangeRate>,
}

#[derive(Deserialize)]
struct ExchangeRate {
    rate: f64,
}

const EXCHANGE_RATE_HOST: &str = "https://price-feed.dev.fedibtc.com/";

/// Cached exchange rate: BTC price in user's currency (e.g., 94000.0 for $94k)
pub(crate) type ExchangeRateCache = Arc<Mutex<Option<(f64, Instant)>>>;

/// How long a cached exchange rate is considered fresh before it is re-fetched
/// (and before [`crate::client::ConduitClient::sats_to_fiat`] stops using it).
pub(crate) const EXCHANGE_RATE_TTL: Duration = Duration::from_secs(3600);

pub(crate) async fn fetch_exchange_rate(
    cache: ExchangeRateCache,
    currency_code: String,
) -> Result<f64, String> {
    let mut guard = cache.lock().await;

    if let Some((rate, timestamp)) = guard.as_ref()
        && timestamp.elapsed() < EXCHANGE_RATE_TTL
    {
        return Ok(*rate);
    }

    let response = reqwest::get("https://price-feed.dev.fedibtc.com/latest")
        .await
        .map_err(|_| {
            crate::bandwidth::count_web_request(EXCHANGE_RATE_HOST, "exchange_rate", 0, None);
            "Failed to fetch exchange rates".to_string()
        })?;

    let bytes = response.bytes().await.map_err(|_| {
        crate::bandwidth::count_web_request(EXCHANGE_RATE_HOST, "exchange_rate", 0, None);
        "Failed to parse exchange rates".to_string()
    })?;

    let response: FediPriceResponse = serde_json::from_slice(&bytes).map_err(|_| {
        crate::bandwidth::count_web_request(EXCHANGE_RATE_HOST, "exchange_rate", 0, None);
        "Failed to parse exchange rates".to_string()
    })?;

    crate::bandwidth::count_web_request(
        EXCHANGE_RATE_HOST,
        "exchange_rate",
        0,
        Some(bytes.len() as u64),
    );

    let btc_to_usd = response
        .prices
        .get("BTC/USD")
        .ok_or("BTC/USD rate not found")?
        .rate;

    let btc_to_currency = if currency_code == "USD" {
        btc_to_usd
    } else {
        let currency_to_usd = response
            .prices
            .get(&format!("{currency_code}/USD"))
            .ok_or("Currency not supported")?
            .rate;
        btc_to_usd / currency_to_usd
    };

    *guard = Some((btc_to_currency, Instant::now()));

    Ok(btc_to_currency)
}

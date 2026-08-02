---
name: analyzing-debug-exports
description: Use when analyzing a Conduit debug export (conduit-debug-*.tar containing a client DB snapshot and tracing logs) — payment latency breakdowns, LN send/receive failures, refunds, federation or gateway performance questions, or preparing findings for publication.
---

# Analyzing Conduit Debug Exports

## Overview

Debug exports come from the in-app "Export Debug Data" button
(`rust/src/factory.rs` `export_debug_archive`). A tar contains:

- `db/` — full RocksDB snapshot of the client DB (all federations, **live
  wallet secrets** — see Privacy)
- `logs/conduit-<unix-ts>.log` — tracing since the previous successful
  export. Multiple files = leftovers from earlier failed exports. Events
  before the window live only in the DB event log.
- `export-info.txt` — export unix time + app version

All log timestamps are **UTC** (device local time is typically UTC+2).
Log filter: `fm=debug` with TRACE on `fm::timing`, `fm::net`,
`fm::client::net`, `fm::client::module::ln[v2]` (`rust/src/logging.rs`).

Extract into the session scratchpad, never into the repo. Prior analyses of
earlier exports (methodology + numbers to compare against) live in the gist:
https://gist.github.com/elsiribot/479f7c85ead1c15b9c82106e7675f1a9

## Enumerating payments

```bash
grep -oE 'operation_id=[a-f0-9_]+' conduit-*.log | sort | uniq -c | sort -rn
```

LNv2 sends contain `Outgoing(OutgoingContract { payment_image: Hash(0x…)`.
Outcome is in the terminal reactor line
`State transition complete terminal=true outcome=Inactive { dyn_state: Send(…`:

- `state: Success([…bytes…])` — paid; the byte array is the **preimage**
- `state: Refunding([OutPoint …])` — gateway declined; refund txids follow

`payment_image` **is** the BOLT11 payment hash (= sha256(preimage)).
Receives use `Incoming(IncomingContract …)` and the `receive_lnurl_task`
long-poll (`await_incoming_contracts`).

## Send-flow markers, in order

| Log marker (grep-able) | Meaning | Phase attribution |
|---|---|---|
| `request_with_strategy{method="gateways"}` with NO `spawn{task=…}` prefix | user opened the send flow (background refreshes have a task prefix) | — |
| `Attempting to create a new connection url=https://<gw>` outside a `gateway_send_payment` span — 1st | `POST /routing_info` fee preview shown in UI | — |
| same — 2nd | confirm tapped; `ln_send` re-validates routing info. **This is t0.** | device (+1 gateway RTT) |
| `Finalized and submitting transaction txid=` | funding tx built + signed | device |
| `Transaction submission accepted by peer` | guardian intake ack | network + guardian |
| `Transaction accepted in consensus` | consensus round done | federation |
| `gateway_send_payment{…}` span appears | `POST /send_payment` dispatched | device (SM wakeup gap before it) |
| `Triggered state transition` immediately before the terminal line | gateway response processed | gateway + LN + recipient |
| terminal `dyn_state: Send(…)` | done (t1) | device (~10 ms) |

**Standard phase model** — always measure confirm-tap (t0) → terminal
Success (t1), never mix baselines across payments, so results stay
comparable with prior reports:

1. fee lookup + build/sign funding tx (device; typical 0.6–0.8 s)
2. submit → peer ack (network; ~0.5 s warm, up to ~1.7 s cold)
3. peer ack → consensus accepted (federation; 0.4–0.6 s)
4. consensus → send_payment dispatched (device SM executor; 0.6–1.0 s)
5. send_payment → preimage (gateway+LN; 1.4–1.7 s to date)

E-cash change issuance (mint outputs + `signature_shares`) runs in
parallel and is NOT on the critical path — don't add it to totals.

## Known quirks — check this list before calling something an anomaly

- **Connection-pool churn**: every gateway HTTPS call logs
  `Existing connection is disconnected, removing from pool` and pays a
  fresh TCP+TLS handshake. Known bug, constant noise — not your anomaly.
- **SM executor wakeup gap**: 0.6–1.0 s of pure client-side dead time
  between consensus acceptance and the send_payment dispatch. Known.
- **Cold iroh connections**: within ~2 min of app start, peer-ack can be
  ~3× slower. Check log start / `file logging initialized` before blaming
  the network.
- **Guardian/peer 2** consistently returns
  `Invalid number of signatures shares` (masked by the 7-guardian
  threshold). Known-broken; don't rediscover it.
- **LNv2 carries no failure reason**: a declined send is just a cancel
  signature ~2 s after send_payment. Root cause requires gateway logs —
  say so instead of speculating.
- **Fedimint LNv1 recipient invoices** look odd by design: fresh ephemeral
  payee key per invoice, zero-fee route hint, and scid = the gateway's
  `federation_index` (tiny numbers like 2 or 35). Not LSPS2/JIT.
- Pubkeys print in raw secp debug form (64-byte x‖y), not compressed
  33-byte — payment hashes, txids, and scids are the reliable join keys.

## DB snapshot

`rust/examples/db_smoke.rs` opens a snapshot and scans raw KV pairs
(`cargo run --example db_smoke <db-dir>`); adapt it for deeper decoding.
Quick wins without decoding: the WAL/SSTs contain plaintext BOLT11
invoices and `payment-send` event-log records — the only source for
operations that predate the log window.

## Privacy — before publishing anything

- `db/` is a live wallet: ecash note secrets and seed-derived keys.
  Never publish raw DB bytes; delete the extracted copy when done.
- Never publish **preimages** (proof-of-payment) or invoice payment
  secrets. Payment hashes, txids, timestamps, and amounts are fine — the
  owner shares those deliberately for gateway-side debugging.
- Publish via **unlisted** gists only (`gh gist create` defaults to
  secret; add files to the existing gist with `gh gist edit <id> --add`).

## Reporting conventions

- Phase timelines as mermaid `gantt` with one `section` per actor
  (Device / Network / Federation / Gateway+LN); ms precision via
  `dateFormat HH:mm:ss.SSS`. GitHub renders mermaid in gists.
- Quote UTC timestamps so gateway operators can grep their logs.
- Sample sizes are tiny — present standard deviations as spread
  indicators, and name outlier causes (e.g. cold start) explicitly.

## Common mistakes

- Mixing measurement baselines (confirm-tap vs tx-submission) across
  payments in one report — totals become incomparable.
- Attributing the SM wakeup gap to the federation or gateway.
- Treating pool-churn disconnect lines as the fault under investigation.
- Ignoring extra `conduit-*.log` files or the DB event log, then
  reporting "first payment" for an operation that merely starts the
  log window.

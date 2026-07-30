# Debug Export & File Logging — Design

Personal fork feature ("Eric's Conduit", separate app id for side-by-side
install): a settings button that exports a tar archive containing the current
client DB state and all tracing logs written since the previous export, so an
agent can analyze client state + logs offline for latency, congestion, and
payment-failure problems.

## Context

- Conduit = Flutter UI + Rust core (fedimint 0.11.0 crates) glued with
  flutter_rust_bridge 2.10.0.
- All fedimint crates log via `tracing` with stable targets defined in
  `fedimint-logging` (`fm::client::*`, `fm::net::*`, `fm::timing`, …).
  Today no tracing subscriber is installed in the app, so those logs are
  dropped entirely.
- Latency data (`TimeReporter`) is emitted on `fm::timing` at TRACE;
  per-request API logging (`fm::client::net::api`, `fm::net::ws`) is mostly
  TRACE; payment flow detail is DEBUG/TRACE on `fm::client::module::ln[v2]`.
- The whole app uses one RocksDB (`client.db`) holding every federation's
  client DB under key prefixes. `fedimint_core::db::Database::checkpoint()`
  (public in 0.11) produces a consistent RocksDB checkpoint while the client
  is running.

## Components

### 1. Rust file logging (`rust/src/logging.rs`)

- New FRB function `init_logging(log_dir)` called from `main.dart` right
  after `RustLib.init`, before the database is opened.
- `tracing-subscriber` registry with:
  - a global `EnvFilter`:
    `info,fm=debug,fm::timing=trace,fm::net=trace,fm::client::net=trace,fm::client::module::ln=trace,fm::client::module::lnv2=trace,jsonrpsee_core::client::async_client=off,hyper=off,h2=off,iroh=error`
    — i.e. everything fedimint at DEBUG, plus TRACE on the targets that
    carry latency/network/payment-failure signal, with the same noisy-dep
    mutes fedimint's own `TracingSetup` uses.
  - an `fmt` layer (no ANSI, timestamps) writing to
    `<app-docs>/logs/conduit.log` through a swappable
    `Arc<Mutex<File>>` writer, so the file can be rotated at export time
    without re-initializing the subscriber.
  - on Android additionally a `tracing-android` layer (logcat, tag
    `conduit`) for live debugging.
- `log`-crate output (flutter_rust_bridge internals) stays on the existing
  FRB default handler; no `LogTracer` bridge to avoid double logging.

### 2. Debug archive export (`rust/src/factory.rs` + `logging.rs`)

`ConduitClientFactory::export_debug_archive(log_dir, out_dir) -> Result<String, String>`:

1. Rotate the active log: rename `conduit.log` →
   `conduit-<unix-ts>.log`, open a fresh `conduit.log`, swap the fd in the
   shared writer (rename-then-reopen is safe while the old fd is held).
2. Checkpoint the DB: `self.db.checkpoint(<tmp>/db-checkpoint-<ts>)`.
3. Write a tar (`tar` crate) at `<out_dir>/conduit-debug-<ts>.tar`:
   - `db/` — the RocksDB checkpoint files (full client DB state, all
     federations)
   - `logs/` — every rotated `conduit-*.log` (i.e. everything since the
     last successful export, including leftovers from failed ones)
   - `export-info.txt` — export unix time, app version.
4. On success delete the rotated logs and the checkpoint dir; the fresh
   `conduit.log` keeps accumulating until the next export.

### 3. Flutter UI (`lib/screens/base_screen.dart`)

- New `SettingsCard` "Export Debug Data" in the existing Settings
  `BorderedList` (icon: bug/download).
- Handler: `exportDebugArchive(logDir: <app docs dir>, outDir: <tmp dir>)`,
  then `SharePlus.instance.share(ShareParams(files: [XFile(tarPath)]))` —
  same share flow the app already uses; errors surface via
  `NotificationUtils.showError`.

### 4. Fork rebrand (side-by-side install)

- `applicationId` `app.conduit.wallet` → `app.conduit.wallet.eric`
  (Android `namespace` stays unchanged so `MainActivity` keeps resolving).
- Manifest `android:label` → "Eric's Conduit"; visible app titles in Dart
  updated to match.

### 5. Build

- Provision on Nix: Flutter SDK, Android SDK + NDK 28, Rust (edition 2024)
  with `aarch64-linux-android` target, `cargo-ndk` (no Docker available, so
  `cross` from `build-android.sh` is replaced for this build),
  `flutter_rust_bridge_codegen` 2.10.0 for regenerating bindings.
- Keep the 16 KB page-size link flag from `build-android.sh`.
- Output: release APK (unsigned-release falls back per existing gradle
  config if no `key.properties`).

## Error handling

- `init_logging` failures must not crash the app: log to logcat and
  continue (wallet works without file logging).
- Export returns `Result<_, String>`; any failure (checkpoint, IO, tar)
  is shown as a notification, and rotated-but-unexported logs are simply
  picked up by the next export.

## Privacy note

The archive contains the full client DB (ecash secrets, seed-derived
material, payment history) and verbose logs. Owner is aware and accepts
this for a single-user personal fork; the file leaves the device only via
the user-driven share sheet.

## Testing

- `cargo check`/`clippy` for the Rust side; a unit test for rotate+tar
  logic using a temp dir.
- Manual: build APK, install side-by-side, verify logs accumulate and the
  exported tar contains `db/`, `logs/`, `export-info.txt`.

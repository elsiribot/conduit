use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use flutter_rust_bridge::frb;
use tracing_subscriber::EnvFilter;
use tracing_subscriber::fmt::MakeWriter;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;

const ACTIVE_LOG_FILE: &str = "conduit.log";

/// Everything fedimint at debug, plus trace on the targets carrying
/// latency, network and payment-failure signal. Mutes the same noisy
/// dependencies as fedimint's own `TracingSetup`.
const LOG_FILTER: &str = "info,\
    fm=debug,\
    fm::timing=trace,\
    fm::net=trace,\
    fm::client::net=trace,\
    fm::client::module::ln=trace,\
    fm::client::module::lnv2=trace,\
    jsonrpsee_core::client::async_client=off,\
    hyper=off,\
    h2=off,\
    iroh=error";

struct LogState {
    dir: PathBuf,
    writer: SharedFileWriter,
}

static LOG_STATE: OnceLock<LogState> = OnceLock::new();

/// Log file writer that can be atomically swapped at rotation time without
/// re-initializing the tracing subscriber.
#[derive(Clone)]
struct SharedFileWriter(Arc<Mutex<File>>);

impl Write for SharedFileWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0.lock().expect("poisoned").write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.0.lock().expect("poisoned").flush()
    }
}

impl<'a> MakeWriter<'a> for SharedFileWriter {
    type Writer = SharedFileWriter;

    fn make_writer(&'a self) -> Self::Writer {
        self.clone()
    }
}

fn open_active_log(dir: &Path) -> io::Result<File> {
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join(ACTIVE_LOG_FILE))
}

#[frb]
pub fn init_logging(app_dir: String) -> Result<(), String> {
    let dir = PathBuf::from(app_dir).join("logs");

    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;

    let writer = SharedFileWriter(Arc::new(Mutex::new(
        open_active_log(&dir).map_err(|e| e.to_string())?,
    )));

    let filter = EnvFilter::builder()
        .parse(LOG_FILTER)
        .map_err(|e| e.to_string())?;

    let file_layer = tracing_subscriber::fmt::layer()
        .with_ansi(false)
        .with_writer(writer.clone());

    let registry = tracing_subscriber::registry().with(filter).with(file_layer);

    #[cfg(target_os = "android")]
    let registry = registry.with(tracing_android::layer("conduit").map_err(|e| e.to_string())?);

    registry.try_init().map_err(|e| e.to_string())?;

    LOG_STATE
        .set(LogState { dir, writer })
        .map_err(|_| "logging already initialized".to_string())?;

    tracing::info!(target: "conduit", "file logging initialized");

    Ok(())
}

/// Rotate the active log file and return all rotated log files, including
/// leftovers from earlier exports that did not complete.
pub(crate) fn rotate_logs(timestamp: u64) -> Result<Vec<PathBuf>, String> {
    let Some(state) = LOG_STATE.get() else {
        return Ok(Vec::new());
    };

    let active = state.dir.join(ACTIVE_LOG_FILE);
    let rotated = state.dir.join(format!("conduit-{timestamp}.log"));

    // Move the inode aside and point the shared fd at a fresh file. The lock
    // is held across the swap so no log line is written in between.
    {
        let mut file = state.writer.0.lock().expect("poisoned");

        file.flush().map_err(|e| e.to_string())?;

        std::fs::rename(&active, &rotated).map_err(|e| e.to_string())?;

        *file = open_active_log(&state.dir).map_err(|e| e.to_string())?;
    }

    let mut logs: Vec<PathBuf> = std::fs::read_dir(&state.dir)
        .map_err(|e| e.to_string())?
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("conduit-") && name.ends_with(".log"))
        })
        .collect();

    logs.sort();

    Ok(logs)
}

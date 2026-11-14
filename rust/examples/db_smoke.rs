//! Smoke test for exported debug archives: open the RocksDB snapshot and
//! count raw key-value pairs. Usage: db_smoke <path-to-db-dir>

use fedimint_core::db::{Database, IDatabaseTransactionOpsCore};
use futures_util::StreamExt;

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    let path = std::env::args().nth(1).expect("usage: db_smoke <db-dir>");

    let db: Database = fedimint_rocksdb::RocksDb::open_blocking(&path, None)
        .expect("failed to open db")
        .into();

    let mut dbtx = db.begin_transaction_nc().await;

    let mut entries = dbtx.raw_find_by_prefix(&[]).await.expect("scan failed");

    let mut count: u64 = 0;
    let mut bytes: u64 = 0;
    let mut first_bytes = std::collections::BTreeMap::<u8, u64>::new();

    while let Some((key, value)) = entries.next().await {
        count += 1;
        bytes += (key.len() + value.len()) as u64;
        *first_bytes.entry(key[0]).or_default() += 1;
    }

    println!("entries: {count}");
    println!("total bytes: {bytes}");
    println!("key prefix histogram (first byte -> count): {first_bytes:?}");
}

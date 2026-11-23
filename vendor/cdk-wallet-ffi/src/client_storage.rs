//! Desktop adapter. `SqliteClientStorage` owns channel material; the local
//! tables hold consent, the exact swap journal and the endpoint/send link.
use cdk_spilman::{
    ClientChannelFunding, ClientChannelOpeningFromSwap, ClientChannelState, ClientStorage,
    SqliteClientStorage,
};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use safer_ffi::prelude::*;
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::time::Duration;
use zeroize::Zeroizing;

use crate::api::{guard, opt_cstr_to_string};
use crate::wallet::{FfiErr, FfiResult};
use crate::{CdkBytesResult, CdkStatus, CdkStatusResult};

const MAX_RECORD: usize = 6 * 1024 * 1024 + 1024;
const JOURNAL: &[u8] = b"journal";
const WALLET: &[u8] = b"wallet";
const HOE_LIFECYCLE: &[u8] = b"hoe-lifecycle";

#[derive_ReprC]
#[repr(opaque)]
pub struct CdkSpilmanClientStorage {
    app: Connection,
    client: SqliteClientStorage,
}

#[derive_ReprC]
#[repr(C)]
pub struct CdkSpilmanClientStorageOpenResult {
    pub status: CdkStatus,
    pub error: Option<char_p::Box>,
    pub handle: Option<repr_c::Box<CdkSpilmanClientStorage>>,
}

// v1 desktop transfer envelope (also the legacy SQLite record format).
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ChannelRecord {
    version: u32,
    #[serde(deserialize_with = "zig_bytes")]
    scope: [u8; 32],
    channel: Funded,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Funded {
    #[serde(deserialize_with = "zig_bytes")]
    operation_id: [u8; 16],
    #[serde(deserialize_with = "zig_bytes")]
    id: [u8; 32],
    mint_url: String,
    capacity_msats: u64,
    refund_time: u64,
    channel_secret_hex: String,
    params_json: String,
    keyset_json: String,
    funding_proofs_json: String,
}

// Zig's JSON writer emits byte arrays as strings when the bytes are UTF-8.
fn zig_bytes<'de, D: serde::Deserializer<'de>, const N: usize>(d: D) -> Result<[u8; N], D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Bytes {
        Text(String),
        Array(Vec<u8>),
    }
    let bytes = match Bytes::deserialize(d)? {
        Bytes::Text(text) => text.into_bytes(),
        Bytes::Array(bytes) => bytes,
    };
    bytes
        .try_into()
        .map_err(|_| serde::de::Error::custom("invalid byte array length"))
}

#[derive(Deserialize)]
struct Params {
    sender_pubkey: String,
    receiver_pubkey: String,
    mint: String,
    unit: String,
    capacity: u64,
    funding_token_amount: u64,
    expiry_timestamp: u64,
    setup_timestamp: u64,
}

fn err(status: CdkStatus, message: &'static str) -> FfiErr {
    FfiErr::new(status, message)
}

fn db(_: impl std::fmt::Display) -> FfiErr {
    err(CdkStatus::DatabaseError, "Spilman SQLite operation failed")
}

fn invalid_record() -> FfiErr {
    err(
        CdkStatus::UnsupportedDatabase,
        "invalid Spilman channel record",
    )
}

fn conflict() -> FfiErr {
    err(CdkStatus::AlreadyOpen, "conflicting Spilman channel")
}

fn missing() -> FfiErr {
    err(CdkStatus::OperationNotFound, "Spilman record not found")
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

impl Funded {
    fn params(&self) -> FfiResult<Params> {
        let p: Params = serde_json::from_str(&self.params_json).map_err(|_| invalid_record())?;
        if p.mint != self.mint_url
            || p.unit != "msat"
            || p.capacity != self.capacity_msats
            || p.capacity == 0
            || p.expiry_timestamp == 0
            || p.expiry_timestamp != self.refund_time
            || p.funding_token_amount == 0
            || !matches!(
                serde_json::from_str(&self.funding_proofs_json),
                Ok(serde_json::Value::Array(_))
            )
            || cdk_spilman::channel_parameters_get_channel_id(
                &self.params_json,
                &self.channel_secret_hex,
                &self.keyset_json,
            )
            .map_err(|_| invalid_record())?
                != hex(&self.id)
        {
            return Err(invalid_record());
        }
        Ok(p)
    }
}

impl CdkSpilmanClientStorage {
    fn open(path: &str) -> FfiResult<Self> {
        if !Path::new(path).is_absolute() {
            return Err(err(CdkStatus::InvalidPath, "storage path must be absolute"));
        }
        let app = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )
        .map_err(db)?;
        app.busy_timeout(Duration::from_secs(5)).map_err(db)?;
        app.execute_batch(
            "PRAGMA trusted_schema=OFF; PRAGMA synchronous=EXTRA; PRAGMA fullfsync=ON;",
        )
        .map_err(db)?;
        let client = SqliteClientStorage::open(path).map_err(db)?;
        app.execute_batch(
            "CREATE TABLE IF NOT EXISTS records (
                namespace BLOB NOT NULL, id BLOB NOT NULL, data BLOB NOT NULL,
                PRIMARY KEY(namespace,id)
             ) WITHOUT ROWID;
             CREATE TABLE IF NOT EXISTS haystack_channel_links (
                id BLOB PRIMARY KEY CHECK(length(id)=32),
                scope BLOB NOT NULL CHECK(length(scope)=32),
                operation_id BLOB NOT NULL CHECK(length(operation_id)=16)
             ) WITHOUT ROWID;
             CREATE INDEX IF NOT EXISTS haystack_channel_scope ON haystack_channel_links(scope);",
        )
        .map_err(db)?;
        let mut storage = Self { app, client };
        storage.migrate_channels()?;
        Ok(storage)
    }

    fn migrate_channels(&mut self) -> FfiResult<()> {
        loop {
            let row: Option<(Vec<u8>, Vec<u8>, Vec<u8>)> = self
                .app
                .query_row(
                    "SELECT namespace,id,data FROM records WHERE namespace NOT IN (?1,?2,?3) LIMIT 1",
                    params![JOURNAL, WALLET, HOE_LIFECYCLE],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )
                .optional()
                .map_err(db)?;
            let Some((scope, id, json)) = row else {
                return Ok(());
            };
            let json = Zeroizing::new(json);
            let record = parse_channel(&json)?;
            if scope != record.scope || id != record.channel.id {
                return Err(invalid_record());
            }
            // The legacy record is already funded and may no longer have its
            // journal. Keep it until the upstream replacement is committed.
            self.save_channel(record, String::new())?;
            self.app
                .execute(
                    "DELETE FROM records WHERE namespace=?1 AND id=?2",
                    params![scope, id],
                )
                .map_err(db)?;
        }
    }

    fn link(&self, id: &[u8]) -> FfiResult<Option<(Vec<u8>, [u8; 16])>> {
        self.app
            .query_row(
                "SELECT scope,operation_id FROM haystack_channel_links WHERE id=?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .map_err(db)
    }

    fn save_channel(&mut self, record: ChannelRecord, input_token: String) -> FfiResult<()> {
        let f = record.channel;
        let p = f.params()?;
        let id = hex(&f.id);
        let state = self.client.get_state(&id);
        if let Some((scope, operation)) = self.link(&f.id)? {
            if scope != record.scope || operation != f.operation_id {
                return Err(conflict());
            }
        } else {
            if state.is_some() {
                return Err(conflict());
            }
            // This is deliberately the first commit. Every completed upstream
            // row has a recoverable link. If interrupted before set_open, the
            // funding journal (or legacy row) is still authoritative on retry.
            self.app
                .execute(
                    "INSERT INTO haystack_channel_links(id,scope,operation_id) VALUES(?1,?2,?3)",
                    params![f.id, record.scope, f.operation_id],
                )
                .map_err(db)?;
        }
        let expected = ClientChannelFunding {
            params_json: f.params_json,
            funding_proofs_json: f.funding_proofs_json,
            channel_secret_hex: f.channel_secret_hex,
            keyset_info_json: f.keyset_json,
            sender_pubkey_hex: p.sender_pubkey,
            capacity: p.capacity,
            funding_token_amount: p.funding_token_amount,
            mint_url: p.mint,
            created_at: p.setup_timestamp,
        };
        match state {
            Some(
                ClientChannelState::Open | ClientChannelState::Closing | ClientChannelState::Closed,
            ) => {
                return match self.client.get_funding(&id) {
                    Some(existing) if existing == expected => Ok(()),
                    Some(_) => Err(conflict()),
                    None => Err(invalid_record()),
                };
            }
            Some(ClientChannelState::OpeningFailed) => return Err(conflict()),
            _ => {}
        }
        let opening = ClientChannelOpeningFromSwap {
            params_json: expected.params_json,
            channel_secret_hex: expected.channel_secret_hex,
            keyset_info_json: expected.keyset_info_json,
            sender_pubkey_hex: expected.sender_pubkey_hex,
            receiver_pubkey_hex: p.receiver_pubkey,
            capacity: expected.capacity,
            funding_token_amount: expected.funding_token_amount,
            mint_url: expected.mint_url,
            unit: p.unit,
            input_token,
            change_secrets_json: String::new(),
            change_amount_raw: 0,
            created_at: expected.created_at,
        };
        if let Some(existing) = self.client.get_opening_from_swap(&id).map_err(db)? {
            if existing != opening {
                return Err(conflict());
            }
        } else {
            self.client
                .save_opening_from_swap(&id, opening)
                .map_err(db)?;
        }
        self.client
            .set_open(&id, &expected.funding_proofs_json)
            .map_err(db)
    }

    fn read_channel(&self, scope: [u8; 32], id: [u8; 32]) -> FfiResult<Vec<u8>> {
        let Some((linked_scope, operation_id)) = self.link(&id)? else {
            return Err(missing());
        };
        if linked_scope != scope {
            return Err(missing());
        }
        let f = self
            .client
            .get_funding(&hex(&id))
            .ok_or_else(|| invalid_record())?;
        let p: Params = serde_json::from_str(&f.params_json).map_err(|_| invalid_record())?;
        serde_json::to_vec(&ChannelRecord {
            version: 1,
            scope,
            channel: Funded {
                operation_id,
                id,
                mint_url: f.mint_url,
                capacity_msats: f.capacity,
                refund_time: p.expiry_timestamp,
                channel_secret_hex: f.channel_secret_hex,
                params_json: f.params_json,
                keyset_json: f.keyset_info_json,
                funding_proofs_json: f.funding_proofs_json,
            },
        })
        .map_err(db)
    }
}

fn parse_channel(data: &[u8]) -> FfiResult<ChannelRecord> {
    if data.len() > MAX_RECORD {
        return Err(invalid_record());
    }
    let r: ChannelRecord = serde_json::from_slice(data).map_err(|_| invalid_record())?;
    if r.version != 1 {
        return Err(invalid_record());
    }
    Ok(r)
}

fn handle_error() -> FfiErr {
    err(CdkStatus::NullArgument, "storage handle is NULL")
}

fn guarded<T>(f: impl FnOnce() -> FfiResult<T>) -> FfiResult<T> {
    guard(
        || {
            Err(err(
                CdkStatus::InternalError,
                "internal Spilman storage panic",
            ))
        },
        f,
    )
}

fn bytes(f: impl FnOnce() -> FfiResult<Vec<u8>>) -> CdkBytesResult {
    match guarded(f) {
        Ok(bytes) => CdkBytesResult {
            status: CdkStatus::Ok,
            error: None,
            bytes: bytes.into(),
        },
        Err(e) => CdkBytesResult::err(e.status, e.message),
    }
}

fn status(f: impl FnOnce() -> FfiResult<()>) -> CdkStatusResult {
    match guarded(f) {
        Ok(()) => CdkStatusResult::ok(),
        Err(e) => CdkStatusResult::err(e.status, e.message),
    }
}

fn array<const N: usize>(slice: c_slice::Ref<'_, u8>) -> FfiResult<[u8; N]> {
    slice.as_slice().try_into().map_err(|_| {
        err(
            CdkStatus::InvalidArgument,
            "invalid Spilman identifier length",
        )
    })
}

fn metadata_key(namespace: &[u8], id: &[u8]) -> FfiResult<()> {
    if (namespace == JOURNAL && id.len() == 16)
        || (namespace == WALLET && id == b"pending")
        || (namespace == HOE_LIFECYCLE && id.len() == 32)
    {
        Ok(())
    } else {
        Err(err(
            CdkStatus::InvalidArgument,
            "invalid Spilman metadata key",
        ))
    }
}

/// Open a pre-created, private database. The caller must verify the directory,
/// file and any SQLite sidecars, and hold the wallet instance lock throughout
/// use. Calls (including across handles for the same file) must be serialized.
#[ffi_export]
pub fn cdk_spilman_client_storage_open(
    path: Option<char_p::Ref<'_>>,
) -> CdkSpilmanClientStorageOpenResult {
    match guarded(|| CdkSpilmanClientStorage::open(&opt_cstr_to_string(path)?)) {
        Ok(storage) => CdkSpilmanClientStorageOpenResult {
            status: CdkStatus::Ok,
            error: None,
            handle: Some(Box::new(storage).into()),
        },
        Err(e) => CdkSpilmanClientStorageOpenResult {
            status: e.status,
            error: crate::status::string_to_box(e.message),
            handle: None,
        },
    }
}

#[ffi_export]
pub fn cdk_spilman_client_storage_close(storage: Option<repr_c::Box<CdkSpilmanClientStorage>>) {
    let _ = guarded(|| {
        drop(storage);
        Ok(())
    });
}

/// Persist verified funding using the upstream opening-to-open transition.
/// The caller must retain its exact swap journal until reconciliation.
#[ffi_export]
pub fn cdk_spilman_client_storage_save_funded(
    storage: Option<&mut CdkSpilmanClientStorage>,
    record: c_slice::Ref<'_, u8>,
    request: c_slice::Ref<'_, u8>,
) -> CdkStatusResult {
    status(|| {
        let storage = storage.ok_or_else(handle_error)?;
        let r = parse_channel(record.as_slice())?;
        let input = if request.as_slice().is_empty() {
            // A retry after journal retirement is allowed only if the linked
            // channel is already funded (save_channel compares it in full).
            if !matches!(
                storage.client.get_state(&hex(&r.channel.id)),
                Some(
                    ClientChannelState::Open
                        | ClientChannelState::Closing
                        | ClientChannelState::Closed
                )
            ) {
                return Err(missing());
            }
            String::new()
        } else {
            #[derive(Deserialize)]
            struct Request {
                inputs: Vec<serde_json::Value>,
            }
            let swap: Request =
                serde_json::from_slice(request.as_slice()).map_err(|_| invalid_record())?;
            serde_json::to_string(&swap.inputs).map_err(db)?
        };
        storage.save_channel(r, input)
    })
}

#[ffi_export]
pub fn cdk_spilman_client_storage_read_funded(
    storage: Option<&CdkSpilmanClientStorage>,
    scope: c_slice::Ref<'_, u8>,
    id: c_slice::Ref<'_, u8>,
) -> CdkBytesResult {
    bytes(|| {
        storage
            .ok_or_else(handle_error)?
            .read_channel(array(scope)?, array(id)?)
    })
}

/// Read an opaque application recovery record. Free bytes with cdk_bytes_free.
#[ffi_export]
pub fn cdk_spilman_client_storage_read_metadata(
    storage: Option<&CdkSpilmanClientStorage>,
    namespace: c_slice::Ref<'_, u8>,
    id: c_slice::Ref<'_, u8>,
) -> CdkBytesResult {
    bytes(|| {
        let storage = storage.ok_or_else(handle_error)?;
        let (ns, id) = (namespace.as_slice(), id.as_slice());
        metadata_key(ns, id)?;
        storage
            .app
            .query_row(
                "SELECT data FROM records WHERE namespace=?1 AND id=?2",
                params![ns, id],
                |r| r.get(0),
            )
            .optional()
            .map_err(db)?
            .ok_or_else(missing)
    })
}

#[ffi_export]
pub fn cdk_spilman_client_storage_write_metadata(
    storage: Option<&CdkSpilmanClientStorage>,
    namespace: c_slice::Ref<'_, u8>,
    id: c_slice::Ref<'_, u8>,
    data: c_slice::Ref<'_, u8>,
    replace: bool,
) -> CdkStatusResult {
    status(|| {
        let storage = storage.ok_or_else(handle_error)?;
        let (ns, id) = (namespace.as_slice(), id.as_slice());
        metadata_key(ns, id)?;
        if data.len() > MAX_RECORD {
            return Err(invalid_record());
        }
        let sql = if replace {
            "INSERT INTO records(namespace,id,data) VALUES(?1,?2,?3) ON CONFLICT(namespace,id) DO UPDATE SET data=excluded.data"
        } else {
            "INSERT INTO records(namespace,id,data) VALUES(?1,?2,?3) ON CONFLICT(namespace,id) DO NOTHING"
        };
        if storage
            .app
            .execute(sql, params![ns, id, data.as_slice()])
            .map_err(db)?
            != 1
        {
            return Err(conflict());
        }
        Ok(())
    })
}

#[ffi_export]
pub fn cdk_spilman_client_storage_remove_metadata(
    storage: Option<&CdkSpilmanClientStorage>,
    namespace: c_slice::Ref<'_, u8>,
    id: c_slice::Ref<'_, u8>,
) -> CdkStatusResult {
    status(|| {
        let storage = storage.ok_or_else(handle_error)?;
        let (ns, id) = (namespace.as_slice(), id.as_slice());
        metadata_key(ns, id)?;
        storage
            .app
            .execute(
                "DELETE FROM records WHERE namespace=?1 AND id=?2",
                params![ns, id],
            )
            .map_err(db)?;
        Ok(())
    })
}

/// Return concatenated fixed-width IDs: 16 bytes each for the journal, or
/// 32 bytes each for the supplied channel scope. Free with cdk_bytes_free.
#[ffi_export]
pub fn cdk_spilman_client_storage_list_ids(
    storage: Option<&CdkSpilmanClientStorage>,
    scope_or_journal: c_slice::Ref<'_, u8>,
) -> CdkBytesResult {
    bytes(|| {
        let storage = storage.ok_or_else(handle_error)?;
        let key = scope_or_journal.as_slice();
        let (sql, size) = if key == JOURNAL {
            ("SELECT id FROM records WHERE namespace=?1", 16)
        } else if key.len() == 32 {
            (
                "SELECT id,operation_id FROM haystack_channel_links WHERE scope=?1",
                32,
            )
        } else {
            return Err(err(
                CdkStatus::InvalidArgument,
                "invalid Spilman list scope",
            ));
        };
        let mut stmt = storage.app.prepare(sql).map_err(db)?;
        let mut rows = stmt.query([key]).map_err(db)?;
        let mut result = Vec::new();
        while let Some(row) = rows.next().map_err(db)? {
            let id: Vec<u8> = row.get(0).map_err(db)?;
            if id.len() != size {
                return Err(invalid_record());
            }
            if size == 32
                && matches!(
                    storage.client.get_state(&hex(&id)),
                    None | Some(ClientChannelState::OpeningFromSwap)
                )
            {
                // An interrupted local save is still handled by the exact
                // funding journal and wallet marker, not as a funded channel.
                let operation: [u8; 16] = row.get(1).map_err(db)?;
                let journaled: bool = storage
                    .app
                    .query_row(
                        "SELECT EXISTS(SELECT 1 FROM records WHERE namespace=?1 AND id=?2)",
                        params![JOURNAL, operation],
                        |row| row.get(0),
                    )
                    .map_err(db)?;
                if journaled {
                    continue;
                }
                return Err(invalid_record());
            }
            result.extend(id);
        }
        Ok(result)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn legacy_record() -> ChannelRecord {
        let sender = "034f355bdcb7cc0af728ef3cceb9615d90684bb5b2ca5f859ab0f0b704075871aa";
        let receiver = "02466d7fcae563e5cb09a0d1870bb580344804617879a14949cf22285f1bae3f27";
        let mint = "https://mint.example";
        let keyset = "00891271bfa74eb8";
        let params = serde_json::json!({
            "sender_pubkey": sender, "receiver_pubkey": receiver, "mint": mint, "unit": "msat",
            "capacity": 32, "expiry_timestamp": 4000000000u64, "setup_timestamp": 1,
            "funding_token_amount": 32, "maximum_amount": 32, "keyset_id": keyset, "input_fee_ppk": 0,
        }).to_string();
        let keys = serde_json::json!({
            "keyset_id": keyset, "unit": "msat", "input_fee_ppk": 0,
            "keys": { "32": "03d30199d74fb5a22d47b6e054e2f378cedacffcb89904a61d75d0dbd407143e65" },
        })
        .to_string();
        let secret = "ab".repeat(32);
        let id = cdk_spilman::channel_parameters_get_channel_id(&params, &secret, &keys).unwrap();
        let id = std::array::from_fn(|i| u8::from_str_radix(&id[2 * i..2 * i + 2], 16).unwrap());
        ChannelRecord {
            version: 1,
            scope: [2; 32],
            channel: Funded {
                id,
                operation_id: [3; 16],
                mint_url: mint.into(),
                capacity_msats: 32,
                refund_time: 4000000000,
                channel_secret_hex: secret,
                params_json: params,
                keyset_json: keys,
                funding_proofs_json: "[ { \"test\": \"proof bytes\" } ]\n".into(),
            },
        }
    }

    #[test]
    fn discovery_leaves_an_interrupted_funding_link_to_its_journal() {
        let tempfile = tempfile::NamedTempFile::new().unwrap();
        let mut store = CdkSpilmanClientStorage::open(tempfile.path().to_str().unwrap()).unwrap();
        let record = legacy_record();
        let scope = record.scope;
        let id = record.channel.id;
        let op = record.channel.operation_id;
        store
            .app
            .execute(
                "INSERT INTO haystack_channel_links VALUES(?1,?2,?3)",
                params![id, scope, op],
            )
            .unwrap();
        let list = |store: &CdkSpilmanClientStorage| {
            cdk_spilman_client_storage_list_ids(Some(store), c_slice::Ref::from(scope.as_slice()))
        };
        assert_eq!(list(&store).status, CdkStatus::UnsupportedDatabase);
        store
            .app
            .execute(
                "INSERT INTO records VALUES(?1,?2,?3)",
                params![JOURNAL, op, b"funding journal"],
            )
            .unwrap();
        let incomplete = list(&store);
        assert_eq!(incomplete.status, CdkStatus::Ok);
        assert!(incomplete.bytes.is_empty());
        store.save_channel(record, String::new()).unwrap();
        let funded = list(&store);
        assert_eq!(funded.status, CdkStatus::Ok);
        assert_eq!(&funded.bytes[..], id.as_slice());
    }

    #[test]
    fn interrupted_legacy_migration_reopens_through_upstream_storage() {
        let tempfile = tempfile::NamedTempFile::new().unwrap();
        let path = tempfile.path().to_str().unwrap();
        let record = legacy_record();
        let id = hex(&record.channel.id);
        let canonical = serde_json::to_vec(&record).unwrap();
        let mut legacy = serde_json::to_value(&record).unwrap();
        legacy["scope"] = String::from_utf8(record.scope.to_vec()).unwrap().into();
        legacy["channel"]["operation_id"] = String::from_utf8(record.channel.operation_id.to_vec())
            .unwrap()
            .into();
        let legacy = serde_json::to_vec(&legacy).unwrap();
        let app = Connection::open(path).unwrap();
        app.execute_batch("CREATE TABLE records(namespace BLOB NOT NULL, id BLOB NOT NULL, data BLOB NOT NULL, PRIMARY KEY(namespace,id)) WITHOUT ROWID;").unwrap();
        let metadata = b"exact application recovery bytes";
        app.execute(
            "INSERT INTO records VALUES(?1,?2,?3)",
            params![JOURNAL, record.channel.operation_id, metadata],
        )
        .unwrap();
        app.execute(
            "INSERT INTO records VALUES(?1,?2,?3)",
            params![record.scope, record.channel.id, legacy],
        )
        .unwrap();
        let upstream = SqliteClientStorage::open(path).unwrap();
        app.execute_batch("CREATE TRIGGER block_completion BEFORE UPDATE OF funding_json ON spilman_client_channels BEGIN SELECT RAISE(ABORT, 'test interruption'); END;").unwrap();

        assert_eq!(
            CdkSpilmanClientStorage::open(path).err().unwrap().status,
            CdkStatus::DatabaseError
        );
        assert_eq!(
            upstream.get_state(&id),
            Some(ClientChannelState::OpeningFromSwap)
        );
        let still_saved: Vec<u8> = app
            .query_row(
                "SELECT data FROM records WHERE namespace=?1",
                [record.scope],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(still_saved, legacy);
        app.execute_batch("DROP TRIGGER block_completion").unwrap();

        let store = CdkSpilmanClientStorage::open(path).unwrap();
        assert_eq!(upstream.get_state(&id), Some(ClientChannelState::Open));
        assert_eq!(
            upstream.get_funding(&id).unwrap().funding_proofs_json,
            record.channel.funding_proofs_json
        );
        assert_eq!(
            store.read_channel(record.scope, record.channel.id).unwrap(),
            canonical
        );
        let records: i64 = app
            .query_row("SELECT count(*) FROM records", [], |r| r.get(0))
            .unwrap();
        assert_eq!(records, 1);
        let still_saved: Vec<u8> = app
            .query_row(
                "SELECT data FROM records WHERE namespace=?1",
                [JOURNAL],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(still_saved, metadata);
    }

    #[test]
    fn malformed_legacy_record_is_not_discarded() {
        let tempfile = tempfile::NamedTempFile::new().unwrap();
        let path = tempfile.path().to_str().unwrap();
        let store = CdkSpilmanClientStorage::open(path).unwrap();
        let payload = b"malformed recovery record";
        store
            .app
            .execute(
                "INSERT INTO records VALUES(?1,?2,?3)",
                params![[1u8; 32], [2u8; 32], payload],
            )
            .unwrap();
        assert_eq!(
            CdkSpilmanClientStorage::open(path).err().unwrap().status,
            CdkStatus::UnsupportedDatabase
        );
        let saved: Vec<u8> = store
            .app
            .query_row("SELECT data FROM records", [], |r| r.get(0))
            .unwrap();
        assert_eq!(saved, payload);
    }
}

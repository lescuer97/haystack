//! Native adapter for upstream Spilman receiver storage. The wallet service
//! owns authorization, scheduling, and mint I/O; these calls only persist state.
use cdk_spilman::configurable_host::{ClosedDataView, SpilmanStorage, SqliteStorage};
use cdk_spilman::{ChannelFunding, ClosingData, PaymentProof};
use safer_ffi::prelude::*;
use serde::Deserialize;

use crate::api::{guard, opt_cstr_to_string};
use crate::wallet::{FfiErr, FfiResult};
use crate::{CdkStatus, CdkStatusResult};

#[derive_ReprC]
#[repr(opaque)]
pub struct CdkSpilmanReceiverStorage(SqliteStorage);

#[derive_ReprC]
#[repr(C)]
pub struct CdkSpilmanReceiverStorageOpenResult {
    pub status: CdkStatus,
    pub error: Option<char_p::Box>,
    pub handle: Option<repr_c::Box<CdkSpilmanReceiverStorage>>,
}

fn db(_: String) -> FfiErr {
    FfiErr::new(CdkStatus::DatabaseError, "Spilman receiver storage failed")
}

/// Open the private database already checked by the wallet service.
#[ffi_export]
pub fn cdk_spilman_receiver_storage_open(
    path: Option<char_p::Ref<'_>>,
) -> CdkSpilmanReceiverStorageOpenResult {
    match guard(
        || Err(FfiErr::new(CdkStatus::InternalError, "internal panic")),
        || {
            SqliteStorage::open(&opt_cstr_to_string(path)?)
                .map(CdkSpilmanReceiverStorage)
                .map_err(db)
        },
    ) {
        Ok(storage) => CdkSpilmanReceiverStorageOpenResult {
            status: CdkStatus::Ok,
            error: None,
            handle: Some(Box::new(storage).into()),
        },
        Err(e) => CdkSpilmanReceiverStorageOpenResult {
            status: e.status,
            error: crate::status::string_to_box(e.message),
            handle: None,
        },
    }
}

#[ffi_export]
pub fn cdk_spilman_receiver_storage_close(storage: Option<repr_c::Box<CdkSpilmanReceiverStorage>>) {
    drop(storage);
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Write {
    Fund {
        funding: ChannelFunding,
    },
    Pay {
        expected: PaymentProof,
        payment: PaymentProof,
    },
    Freeze {
        expected: PaymentProof,
        expiry: u64,
        journal: String,
    },
    Finish {
        expected: String,
        payout: ClosedDataView,
    },
}

#[ffi_export]
pub fn cdk_spilman_receiver_storage_write(
    storage: Option<&CdkSpilmanReceiverStorage>,
    id: Option<char_p::Ref<'_>>,
    operation: c_slice::Ref<'_, u8>,
) -> CdkStatusResult {
    guard(
        || CdkStatusResult::err(CdkStatus::InternalError, "internal panic"),
        || match write(storage, id, operation.as_slice()) {
            Ok(()) => CdkStatusResult {
                status: CdkStatus::Ok,
                error: None,
            },
            Err(e) => CdkStatusResult::err(e.status, e.message),
        },
    )
}

fn write(
    storage: Option<&CdkSpilmanReceiverStorage>,
    id: Option<char_p::Ref<'_>>,
    operation: &[u8],
) -> FfiResult<()> {
    fn invalid() -> FfiErr {
        FfiErr::new(
            CdkStatus::InvalidArgument,
            "invalid receiver storage operation",
        )
    }
    let store = &storage.ok_or_else(invalid)?.0;
    let id = opt_cstr_to_string(id)?;
    if id.len() != 64
        || !id
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    {
        return Err(invalid());
    }
    let op = serde_json::from_slice(operation).map_err(|_| invalid())?;
    match op {
        Write::Fund { funding } => store.save_funding(&id, funding),
        Write::Pay { expected, payment } => store.compare_payment(&id, &expected, payment),
        Write::Freeze {
            expected,
            expiry,
            journal,
        } => {
            let closing = ClosingData {
                balance: expected.balance,
                signature: expected.signature.clone(),
                expiry_timestamp: expiry,
            };
            store.freeze_close(&id, &expected, closing, &journal)
        }
        Write::Finish { expected, payout } => {
            store.advance_close(&id, &expected, "complete", Some(payout))
        }
    }
    .map_err(db)
}

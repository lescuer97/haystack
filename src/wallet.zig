pub const cdk = @import("cdk");

/// Spilman functions share the CDK C ABI (`cdk_spilman_*`).
pub const spilman = cdk.c;

/// Check a CDK/Spilman result and consume its Rust-owned error string.
/// Pass a pointer so the error field can be cleared; the caller still owns any
/// payload (including lists and handles) and must use its matching free helper.
/// On failure, inspect result.status for the specific C ABI status code.
pub fn check(result: anytype) error{CdkFailure}!void {
    const status = result.status;
    cdk.c.cdk_string_free(result.@"error");
    result.@"error" = null;
    if (status != cdk.c.CDK_STATUS_OK) return error.CdkFailure;
}

pub const Wallet = struct {
    /// Do not copy: the handle has a single owner.
    wallet: *cdk.c.CdkWallet_t,
    closed: bool = false,

    /// Close consumes the handle even if the ABI reports an error.
    pub fn close(self: *Wallet) error{CdkFailure}!void {
        if (self.closed) return;
        self.closed = true;
        var result = cdk.c.cdk_wallet_close(self.wallet);
        try check(&result);
    }
};

/// Open or create a wallet at the given database path. Call close when finished.
pub fn createWallet(seed: []const u8, db_path: [:0]const u8) error{CdkFailure}!Wallet {
    var result = cdk.c.cdk_wallet_open(cdk.byteSlice(seed), db_path.ptr);
    defer cdk.c.cdk_recovery_reports_free(result.reports);
    try check(&result);
    return .{ .wallet = result.handle orelse return error.CdkFailure };
}

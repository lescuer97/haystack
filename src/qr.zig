//! One cached, bounded Nayuki QR per foreground invoice; no network services.
const std = @import("std");
extern "c" fn qrcodegen_encodeText([*:0]const u8, [*]u8, [*]u8, c_int, c_int, c_int, c_int, bool) bool;
extern "c" fn qrcodegen_getModule([*]const u8, c_int, c_int) bool;
pub const Qr = struct {
    modules: [3918]u8 = @splat(0),
    pub fn encode(self: *Qr, invoice: [:0]const u8) bool {
        var scratch: [3918]u8 = undefined;
        return qrcodegen_encodeText(invoice.ptr, &scratch, &self.modules, 0, 1, 40, -1, true);
    }
    pub fn size(self: *const Qr) u8 {
        return self.modules[0];
    }
    pub fn dark(self: *const Qr, x: c_int, y: c_int) bool {
        return qrcodegen_getModule(&self.modules, x, y);
    }
    pub fn scale(self: *const Qr, pixels: u32) u32 {
        if (self.size() == 0) return 0;
        return pixels / (@as(u32, self.size()) + 8);
    }
};
test "QR encode is cached and refuses truncation, quiet zone fits integer pixels" {
    var qr = Qr{};
    try std.testing.expect(qr.encode("lnbc210n1test"));
    try std.testing.expect(qr.size() >= 21);
    try std.testing.expectEqual(@as(u32, 0), qr.scale(20));
    try std.testing.expectEqual(@as(u32, 2), qr.scale((@as(u32, qr.size()) + 8) * 2));
    const huge: [5000:0]u8 = @splat('a');
    try std.testing.expect(!qr.encode(&huge));
    try std.testing.expectEqual(@as(u8, 0), qr.size());
}

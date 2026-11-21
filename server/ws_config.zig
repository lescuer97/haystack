//! Fixed production admission and buffer bounds.
pub const max_connections = 64;
// The frame cap includes channel open proofs; auth and gameplay have a smaller message cap.
pub const max_payload = @import("shared").protocol.max_request_bytes;
pub const http_head_size = 8192;
pub const max_headers = 32;
pub const port = 9224;

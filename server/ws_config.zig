//! Fixed production admission and buffer bounds.
pub const max_connections = 64;
// Size each receive buffer for the largest supported frame, not the wire codec's
// outer ceiling. Auth and gameplay still have their smaller message caps.
pub const max_payload = @import("shared").protocol.max_channel_open_with_params_bytes;
pub const http_head_size = 8192;
pub const max_headers = 32;
pub const port = 9224;

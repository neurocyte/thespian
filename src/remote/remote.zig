pub const protocol = @import("protocol.zig").ProtocolMessage;
pub const framing = @import("framing.zig");
pub const endpoint = struct {
    pub const subprocess = @import("endpoint_subprocess.zig");
    pub const stdio = @import("endpoint_stdio.zig");
    pub const tcp = @import("endpoint_tcp.zig");
    pub const unx = @import("endpoint_unx.zig");
};

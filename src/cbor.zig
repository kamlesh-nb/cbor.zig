const std = @import("std");
const types = @import("types.zig");
const encoder_mod = @import("encoder.zig");
const decoder_mod = @import("decoder.zig");

// Re-export commonly used types
pub const MajorType = types.MajorType;
pub const SimpleValue = types.SimpleValue;
pub const CborError = types.CborError;
pub const Config = types.Config;
pub const InitialByte = types.InitialByte;
pub const estimateSize = types.estimateSize;

// Re-export main components
pub const Encoder = encoder_mod.Encoder;
pub const Decoder = decoder_mod.Decoder;

// Re-export optional modules
pub const simd = @import("simd.zig");

// Module-specific functionality
pub const encodeEnum = encoder_mod.Encoder.encodeEnum;

// Main CBOR interface
pub const CBOR = struct {
    config: Config,

    pub fn init(config: Config) CBOR {
        return .{ .config = config };
    }

    pub fn encode(self: *CBOR, value: anytype, buffer: []u8) CborError![]const u8 {
        var encoder = Encoder.init(buffer, self.config);
        const len = try encoder.encode(value);
        return buffer[0..len];
    }

    pub fn encodeStream(self: *CBOR, value: anytype, writer: std.io.AnyWriter) CborError!void {
        var encoder = Encoder.initStreaming(writer, self.config);
        _ = try encoder.encode(value);
    }

    pub fn decode(self: *CBOR, comptime T: type, data: []const u8, output: *T) CborError!void {
        var decoder = Decoder.init(data, self.config);
        try decoder.decode(T, output);
    }

    pub fn decodeDebug(self: *CBOR, comptime T: type, data: []const u8, output: *T) CborError!void {
        std.debug.print("CBOR.decodeDebug - Type: {s}, Data length: {}\n", .{ @typeName(T), data.len });
        std.debug.print("Data bytes: ", .{});
        for (data) |byte| {
            std.debug.print("{x:02} ", .{byte});
        }
        std.debug.print("\n", .{});

        var decoder = Decoder.init(data, self.config);
        try decoder.decode(T, output);
    }

    pub fn estimateBufferSize(comptime T: type, value: anytype) usize {
        return estimateSize(T, value);
    }
};

test "cbor" {
    std.testing.refAllDecls(@This());
}

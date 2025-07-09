const std = @import("std");
const types = @import("types.zig");
const simd = @import("simd.zig");

// Encoder module for CBOR encoding
// const extended = @import("extended.zig");

const CborError = types.CborError;
const Config = types.Config;
const MajorType = types.MajorType;
const INDEFINITE_LENGTH = types.INDEFINITE_LENGTH;
const BREAK_MARKER = types.BREAK_MARKER;
const validateType = types.validateType;
const isArrayList = types.isArrayList;

pub const Encoder = struct {
    buffer: []u8,
    pos: usize,
    config: Config,
    depth: u8,
    stream_writer: ?std.io.AnyWriter = null,
    stream_buffer: [4096]u8 = undefined,
    stream_pos: usize = 0,

    pub fn init(buffer: []u8, config: Config) Encoder {
        return .{ .buffer = buffer, .pos = 0, .config = config, .depth = 0 };
    }

    pub fn initStreaming(writer: std.io.AnyWriter, config: Config) Encoder {
        return .{ .buffer = &[_]u8{}, .pos = 0, .config = config, .depth = 0, .stream_writer = writer };
    }

    inline fn flushStream(self: *Encoder) CborError!void {
        if (self.stream_writer) |writer| {
            if (self.stream_pos > 0) {
                writer.writeAll(self.stream_buffer[0..self.stream_pos]) catch return CborError.IoError;
                self.stream_pos = 0;
            }
        }
    }

    inline fn writeByte(self: *Encoder, byte: u8) CborError!void {
        if (self.stream_writer != null) {
            if (self.stream_pos >= self.stream_buffer.len) try self.flushStream();
            self.stream_buffer[self.stream_pos] = byte;
            self.stream_pos += 1;
        } else {
            if (self.pos >= self.buffer.len) return CborError.BufferOverflow;
            self.buffer[self.pos] = byte;
            self.pos += 1;
        }
    }

    inline fn writeSlice(self: *Encoder, data: []const u8) CborError!void {
        if (data.len >= 32 and self.stream_writer == null) {
            // Check bounds before operation
            if (self.pos + data.len > self.buffer.len) return CborError.BufferOverflow;

            // Use SIMD-optimized copy if configuration allows and data is large enough
            if (self.config.use_simd and data.len >= 64) {
                simd.Simd.copyBytes(self.buffer[self.pos..][0..data.len], data);
            } else {
                @memcpy(self.buffer[self.pos..][0..data.len], data);
            }
            self.pos += data.len;
        } else {
            for (data) |byte| {
                try self.writeByte(byte);
            }
        }
    }

    inline fn writeInt(self: *Encoder, comptime T: type, value: T) CborError!void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .big);
        try self.writeSlice(&bytes);
    }

    inline fn writeInitialByte(self: *Encoder, major_type: MajorType, additional_info: u5) CborError!void {
        try self.writeByte(additional_info | (@as(u8, @intFromEnum(major_type)) << 5));
    }

    fn encodeLength(self: *Encoder, major_type: MajorType, length: u64) CborError!void {
        // Check against configured maximum size
        if (length > self.config.max_collection_size) return CborError.InvalidLength;

        // Calculate which length encoding to use based on the size
        if (length < 24) {
            try self.writeInitialByte(major_type, @as(u5, @intCast(length)));
        } else if (length <= 0xFF) {
            try self.writeInitialByte(major_type, 24);
            try self.writeByte(@as(u8, @intCast(length)));
        } else if (length <= 0xFFFF) {
            try self.writeInitialByte(major_type, 25);
            try self.writeInt(u16, @as(u16, @intCast(length)));
        } else if (length <= 0xFFFFFFFF) {
            try self.writeInitialByte(major_type, 26);
            try self.writeInt(u32, @as(u32, @intCast(length)));
        } else {
            try self.writeInitialByte(major_type, 27);
            try self.writeInt(u64, length);
        }
    }

    // Encode integer values directly without collection size checks
    fn encodeIntValue(self: *Encoder, major_type: MajorType, int_value: u64) CborError!void {
        if (int_value < 24) {
            try self.writeInitialByte(major_type, @as(u5, @intCast(int_value)));
        } else if (int_value <= 0xFF) {
            try self.writeInitialByte(major_type, 24);
            try self.writeByte(@as(u8, @intCast(int_value)));
        } else if (int_value <= 0xFFFF) {
            try self.writeInitialByte(major_type, 25);
            try self.writeInt(u16, @as(u16, @intCast(int_value)));
        } else if (int_value <= 0xFFFFFFFF) {
            try self.writeInitialByte(major_type, 26);
            try self.writeInt(u32, @as(u32, @intCast(int_value)));
        } else {
            try self.writeInitialByte(major_type, 27);
            try self.writeInt(u64, int_value);
        }
    }

    pub fn encode(self: *Encoder, value: anytype) CborError!usize {
        try self.encodeValue(value);
        try self.flushStream();
        return self.pos;
    }

    pub fn encodeValue(self: *Encoder, value: anytype) CborError!void {
        if (self.depth >= self.config.max_depth) return CborError.DepthExceeded;
        self.depth += 1;
        defer self.depth -= 1;

        const T = @TypeOf(value);
        comptime validateType(T);

        switch (@typeInfo(T)) {
            .int => try self.encodeInt(value),
            .comptime_int => try self.encodeInt(value),
            .float => try self.encodeFloat(value),
            .bool => try self.encodeBool(value),
            .optional => try self.encodeOptional(value),
            .array => try self.encodeArray(value),
            .@"struct" => {
                if (comptime @hasDecl(T, "encode")) {
                    try value.encode(self);
                } else if (comptime isArrayList(T)) {
                    try self.encodeArrayList(value);
                } else {
                    try self.encodeStruct(value);
                }
            },
            .pointer => try self.encodeText(value),
            .void => try self.encodeNull(),
            .@"enum" => try self.encodeEnum(value),
            .@"union" => @compileError("Union types not yet supported"),
            else => @compileError("Unsupported type"),
        }
    }

    inline fn encodeInt(self: *Encoder, value: anytype) CborError!void {
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);
        comptime if (type_info != .int and type_info != .comptime_int) @compileError("Expected integer type");

        // Fast path for common small integers (0-23)
        if (comptime type_info == .comptime_int or type_info.int.signedness == .unsigned) {
            if (value < 24) {
                return self.writeInitialByte(.unsigned_integer, @as(u5, @intCast(value)));
            }
        } else if (value >= 0) {
            if (value < 24) {
                return self.writeInitialByte(.unsigned_integer, @as(u5, @intCast(value)));
            }
        } else {
            // Fast path for small negative integers (-1 to -24)
            const abs = @as(u64, @intCast(-(value + 1)));
            if (abs < 24) {
                return self.writeInitialByte(.negative_integer, @as(u5, @intCast(abs)));
            }
        }

        // Regular path for larger integers - encode directly without using encodeLength
        if (comptime type_info == .comptime_int or type_info.int.signedness == .unsigned) {
            try self.encodeIntValue(.unsigned_integer, value);
        } else if (value < 0) {
            try self.encodeIntValue(.negative_integer, @as(u64, @intCast(-(value + 1))));
        } else {
            try self.encodeIntValue(.unsigned_integer, @intCast(value));
        }
    }

    inline fn encodeFloat(self: *Encoder, value: anytype) CborError!void {
        const T = @TypeOf(value);

        switch (T) {
            f16 => {
                try self.writeInitialByte(.float_simple, 25);
                try self.writeInt(u16, @bitCast(value));
            },
            f32 => {
                try self.writeInitialByte(.float_simple, 26);
                try self.writeInt(u32, @bitCast(value));
            },
            f64 => {
                try self.writeInitialByte(.float_simple, 27);
                try self.writeInt(u64, @bitCast(value));
            },
            else => @compileError("Unsupported float type: " ++ @typeName(T)),
        }
    }

    inline fn encodeBool(self: *Encoder, value: bool) CborError!void {
        try self.writeInitialByte(.float_simple, if (value) 21 else 20);
    }

    inline fn encodeNull(self: *Encoder) CborError!void {
        try self.writeInitialByte(.float_simple, 22);
    }

    inline fn encodeOptional(self: *Encoder, value: anytype) CborError!void {
        if (value) |v| {
            try self.encodeValue(v);
        } else {
            try self.encodeNull();
        }
    }

    inline fn encodeText(self: *Encoder, text: []const u8) CborError!void {
        if (text.len > self.config.max_string_length) return CborError.InvalidLength;

        // Validate UTF-8 if configured
        if (self.config.validate_utf8) {
            const is_valid = if (self.config.use_simd)
                simd.Simd.validateUtf8(text)
            else
                std.unicode.utf8ValidateSlice(text);

            if (!is_valid) return CborError.InvalidUtf8;
        }

        try self.encodeLength(.text_string, text.len);
        try self.writeSlice(text);
    }

    inline fn encodeBytes(self: *Encoder, bytes: []const u8) CborError!void {
        if (bytes.len > self.config.max_string_length) return CborError.InvalidLength;

        try self.encodeLength(.byte_string, bytes.len);
        try self.writeSlice(bytes);
    }

    fn encodeArray(self: *Encoder, array: anytype) CborError!void {
        @setEvalBranchQuota(10000);
        try self.encodeLength(.array, array.len);
        inline for (array) |item| {
            try self.encodeValue(item);
        }
    }

    inline fn encodeStruct(self: *Encoder, value: anytype) CborError!void {
        const T = @TypeOf(value);
        const fields = @typeInfo(T).@"struct".fields;
        try self.encodeLength(.map, fields.len);
        inline for (fields) |field| {
            try self.encodeText(field.name);
            try self.encodeValue(@field(value, field.name));
        }
    }

    // Encode methods for indefinite-length items
    pub fn encodeIndefiniteArray(self: *Encoder) CborError!void {
        if (!self.config.enable_indefinite_length)
            return CborError.UnsupportedValue;

        if (self.depth >= self.config.max_depth)
            return CborError.DepthExceeded;

        try self.writeInitialByte(.array, INDEFINITE_LENGTH);
        self.depth += 1;
    }

    pub fn encodeIndefiniteMap(self: *Encoder) CborError!void {
        if (!self.config.enable_indefinite_length)
            return CborError.UnsupportedValue;

        if (self.depth >= self.config.max_depth)
            return CborError.DepthExceeded;

        try self.writeInitialByte(.map, INDEFINITE_LENGTH);
        self.depth += 1;
    }

    pub fn encodeIndefiniteString(self: *Encoder) CborError!void {
        if (!self.config.enable_indefinite_length)
            return CborError.UnsupportedValue;

        if (self.depth >= self.config.max_depth)
            return CborError.DepthExceeded;

        try self.writeInitialByte(.text_string, INDEFINITE_LENGTH);
        self.depth += 1;
    }

    pub fn encodeIndefiniteBytes(self: *Encoder) CborError!void {
        if (!self.config.enable_indefinite_length)
            return CborError.UnsupportedValue;

        if (self.depth >= self.config.max_depth)
            return CborError.DepthExceeded;

        try self.writeInitialByte(.byte_string, INDEFINITE_LENGTH);
        self.depth += 1;
    }

    pub fn encodeBreak(self: *Encoder) CborError!void {
        if (self.depth == 0)
            return CborError.InvalidBreakCode;

        try self.writeByte(BREAK_MARKER);
        self.depth -= 1;
    }

    // ArrayList encoding
    fn encodeArrayList(self: *Encoder, list: anytype) CborError!void {
        try self.encodeLength(.array, list.items.len);
        for (list.items) |item| {
            try self.encodeValue(item);
        }
    }

    // Local enum encoding function
    pub fn encodeEnum(self: *Encoder, value: anytype) CborError!void {
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        if (type_info != .Enum) {
            @compileError("Expected enum type");
        }

        // Simple encoding: use the integer value
        const tag_type = type_info.Enum.tag_type;
        const int_value = @intFromEnum(value);

        try self.encodeInt(@as(tag_type, int_value));
    }
};

const std = @import("std");
const types = @import("types.zig");
const simd = @import("simd.zig");

const MajorType = types.MajorType;
const CborError = types.CborError;
const Config = types.Config;
const InitialByte = types.InitialByte;
const INDEFINITE_LENGTH = types.INDEFINITE_LENGTH;
const BREAK_MARKER = types.BREAK_MARKER;
const validateType = types.validateType;
const isArrayList = types.isArrayList;

pub const Decoder = struct {
    data: []const u8,
    pos: usize,
    config: Config,
    depth: u8,
    stream_reader: ?std.io.AnyReader = null,
    stream_buffer: [4096]u8 = undefined,
    stream_pos: usize = 0,
    stream_len: usize = 0,
    allocator: std.mem.Allocator = undefined, // For methods that need allocation

    pub fn init(data: []const u8, config: Config) Decoder {
        return .{ .data = data, .pos = 0, .config = config, .depth = 0 };
    }

    pub fn initStreaming(reader: std.io.AnyReader, config: Config) Decoder {
        return .{ .data = &[_]u8{}, .pos = 0, .config = config, .depth = 0, .stream_reader = reader };
    }

    inline fn fillStreamBuffer(self: *Decoder) CborError!void {
        if (self.stream_reader) |reader| {
            if (self.stream_pos >= self.stream_len) {
                self.stream_len = reader.read(&self.stream_buffer) catch return CborError.IoError;
                self.stream_pos = 0;
                if (self.stream_len == 0) return CborError.BufferUnderflow;
            }
        }
    }

    inline fn readByte(self: *Decoder) CborError!u8 {
        if (self.stream_reader != null) {
            try self.fillStreamBuffer();
            const byte = self.stream_buffer[self.stream_pos];
            self.stream_pos += 1;
            return byte;
        }
        if (self.pos >= self.data.len) {
            return CborError.BufferUnderflow;
        }
        const byte = self.data[self.pos];
        self.pos += 1;
        return byte;
    }

    inline fn readSlice(self: *Decoder, len: usize) CborError![]const u8 {
        if (self.stream_reader != null) {
            if (len > self.stream_buffer.len) return CborError.InvalidLength; // Too large for streaming
            while (self.stream_pos + len > self.stream_len) {
                try self.fillStreamBuffer();
            }
            const slice = self.stream_buffer[self.stream_pos .. self.stream_pos + len];
            self.stream_pos += len;
            return slice;
        }
        if (self.pos + len > self.data.len) return CborError.BufferUnderflow;
        @prefetch(self.data.ptr + self.pos, .{ .locality = 3, .rw = .read });
        const slice = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return slice;
    }

    pub inline fn readInitialByte(self: *Decoder) CborError!InitialByte {
        return @bitCast(try self.readByte());
    }

    fn readLength(self: *Decoder, additional_info: u5) CborError!u64 {
        return switch (additional_info) {
            0...23 => additional_info,
            24 => try self.readByte(),
            25 => std.mem.readInt(u16, (try self.readSlice(2))[0..2], .big),
            26 => std.mem.readInt(u32, (try self.readSlice(4))[0..4], .big),
            27 => std.mem.readInt(u64, (try self.readSlice(8))[0..8], .big),
            else => CborError.InvalidLength,
        };
    }

    pub fn decode(self: *Decoder, comptime T: type, output: *T) CborError!void {
        output.* = try self.decodeValue(T);
    }

    pub fn decodeValue(self: *Decoder, comptime T: type) CborError!T {
        if (self.depth >= self.config.max_depth) return CborError.DepthExceeded;
        self.depth += 1;
        defer self.depth -= 1;

        comptime validateType(T);

        switch (@typeInfo(T)) {
            .int => return try self.decodeIntDebug(T),
            .float => return try self.decodeFloat(T),
            .bool => return try self.decodeBool(),
            .optional => return try self.decodeOptional(T),
            .array => return try self.decodeArray(T),
            .@"struct" => {
                if (comptime @hasDecl(T, "decode")) {
                    return T.decode(self);
                } else if (comptime isArrayList(T)) {
                    return self.decodeArrayList(T);
                } else {
                    return self.decodeStruct(T);
                }
            },
            .pointer => return self.decodeText(),
            .void => {
                try self.expectNull();
                return {};
            },
            else => @compileError("Unsupported type"),
        }
    }

    pub fn decodeValueDebug(self: *Decoder, comptime T: type) CborError!T {
        if (self.depth >= self.config.max_depth) return CborError.DepthExceeded;
        self.depth += 1;
        defer self.depth -= 1;

        comptime validateType(T);
        const type_info = @typeInfo(T);

        switch (type_info) {
            .int => {
                return try self.decodeIntDebug(T);
            },
            .float => {
                return try self.decodeFloat(T);
            },
            .bool => {
                return try self.decodeBool();
            },
            .optional => {
                return try self.decodeOptional(T);
            },
            .array => {
                return try self.decodeArray(T);
            },
            .@"struct" => {
                // Check if this is an ArrayList
                if (comptime isArrayList(T)) {
                    return try self.decodeArrayList(T);
                } else {
                    return try self.decodeStruct(T);
                }
            },
            .pointer => {
                return try self.decodeText();
            },
            .void => {
                try self.expectNull();
                return {};
            },
            else => {
                @compileError("Unsupported type");
            },
        }
    }

    pub fn decodeIntDebug(self: *Decoder, comptime T: type) CborError!T {
        comptime if (@typeInfo(T) != .int) @compileError("Expected integer type");
        const initial = try self.readInitialByte();

        // Fast path for small unsigned integers (0-23)
        if (initial.major_type == @intFromEnum(MajorType.unsigned_integer) and initial.additional_info < 24) {
            const val: u8 = initial.additional_info;
            if (comptime @typeInfo(T).int.signedness == .unsigned) {
                return @intCast(val);
            } else {
                // For signed types, make sure the value fits
                if (comptime @typeInfo(T).int.bits <= 8) {
                    if (val <= std.math.maxInt(T)) {
                        return @intCast(val);
                    }
                } else {
                    return @intCast(val);
                }
            }
        }

        // Fast path for small negative integers
        if (initial.major_type == @intFromEnum(MajorType.negative_integer) and initial.additional_info < 24) {
            if (comptime @typeInfo(T).int.signedness == .unsigned) {
                return CborError.TypeMismatch;
            }

            const abs: u8 = initial.additional_info;
            const neg_val = -@as(i64, @intCast(abs)) - 1;

            // Check if the value fits in the target type
            if (neg_val >= std.math.minInt(T)) {
                return @intCast(neg_val);
            } else {
                return CborError.IntegerOverflow;
            }
        }

        // Regular path for larger integers
        const length = try self.readLength(initial.additional_info);

        switch (initial.major_type) {
            @intFromEnum(MajorType.unsigned_integer) => {
                if (length > std.math.maxInt(T)) return CborError.TypeMismatch;
                return @intCast(length);
            },
            @intFromEnum(MajorType.negative_integer) => {
                if (comptime @typeInfo(T).int.signedness == .unsigned) {
                    return CborError.TypeMismatch;
                }
                const positive = length + 1;
                if (positive > @abs(std.math.minInt(T))) return CborError.TypeMismatch;
                return -@as(T, @intCast(positive));
            },
            else => {
                return CborError.TypeMismatch;
            },
        }
    }

    inline fn decodeFloat(self: *Decoder, comptime T: type) CborError!T {
        const initial = try self.readInitialByte();
        if (initial.major_type != @intFromEnum(MajorType.float_simple)) return CborError.TypeMismatch;

        return switch (initial.additional_info) {
            25 => blk: {
                if (T != f16) return CborError.InvalidFloat;
                const bits = std.mem.readInt(u16, (try self.readSlice(2))[0..2], .big);
                break :blk @bitCast(bits);
            },
            26 => blk: {
                if (T != f32) return CborError.InvalidFloat;
                const bits = std.mem.readInt(u32, (try self.readSlice(4))[0..4], .big);
                break :blk @bitCast(bits);
            },
            27 => blk: {
                if (T != f64) return CborError.InvalidFloat;
                const bits = std.mem.readInt(u64, (try self.readSlice(8))[0..8], .big);
                break :blk @bitCast(bits);
            },
            else => return CborError.InvalidFloat,
        };
    }

    inline fn decodeBool(self: *Decoder) CborError!bool {
        const initial = try self.readInitialByte();
        if (initial.major_type != @intFromEnum(MajorType.float_simple)) return CborError.TypeMismatch;
        return switch (initial.additional_info) {
            20 => false,
            21 => true,
            else => CborError.InvalidBool,
        };
    }

    inline fn expectNull(self: *Decoder) CborError!void {
        const initial = try self.readInitialByte();
        if (initial.major_type != @intFromEnum(MajorType.float_simple) or initial.additional_info != 22) {
            return CborError.TypeMismatch;
        }
    }

    inline fn decodeOptional(self: *Decoder, comptime T: type) CborError!T {
        const initial = try self.readInitialByte();
        if (initial.major_type == @intFromEnum(MajorType.float_simple) and initial.additional_info == 22) {
            return null;
        }
        // Fix: Handle rewind properly for both buffered and streaming modes
        if (self.stream_reader != null) {
            // For streaming mode, we need to handle this differently
            // Save the byte and handle it in decodeValue
            if (self.stream_pos > 0) {
                self.stream_pos -= 1;
            } else {
                // This is a limitation - we can't rewind in streaming mode
                // when the buffer has been consumed. Consider using a lookahead buffer.
                return CborError.BufferUnderflow;
            }
        } else {
            self.pos -= 1; // Rewind for buffered mode
        }
        return try self.decodeValue(@typeInfo(T).optional.child);
    }

    pub inline fn decodeText(self: *Decoder) CborError![]const u8 {
        const initial = try self.readInitialByte();
        if (initial.major_type != @intFromEnum(MajorType.text_string)) return CborError.TypeMismatch;
        const length = try self.readLength(initial.additional_info);
        if (length > self.config.max_string_length) return CborError.InvalidLength;

        const text_slice = try self.readSlice(@intCast(length));

        // Validate UTF-8 if configured
        if (self.config.validate_utf8) {
            const is_valid = if (self.config.use_simd)
                simd.Simd.validateUtf8(text_slice)
            else
                std.unicode.utf8ValidateSlice(text_slice);

            if (!is_valid) return CborError.InvalidUtf8;
        }

        return text_slice;
    }

    // Zero-copy string decoding for non-streaming mode
    pub fn decodeTextZeroCopy(self: *Decoder) CborError![]const u8 {
        if (self.stream_reader != null) {
            // Zero-copy is not available in streaming mode
            return self.decodeText();
        }

        const initial = try self.readInitialByte();
        if (initial.major_type != @intFromEnum(MajorType.text_string))
            return CborError.TypeMismatch;

        // Handle indefinite length - fall back to regular decode
        if (initial.additional_info == INDEFINITE_LENGTH) {
            // Rewind the initial byte
            self.pos -= 1;
            return self.decodeText();
        }

        const length = try self.readLength(initial.additional_info);
        if (length > self.config.max_string_length) return CborError.InvalidLength;

        // Return a slice directly into the original buffer
        if (self.pos + length > self.data.len) return CborError.BufferUnderflow;

        // Validate UTF-8 if configured
        if (self.config.validate_utf8) {
            const slice = self.data[self.pos .. self.pos + @as(usize, @intCast(length))];
            const is_valid = if (self.config.use_simd)
                simd.Simd.validateUtf8(slice)
            else
                std.unicode.utf8ValidateSlice(slice);

            if (!is_valid) return CborError.InvalidUtf8;
        }

        const result = self.data[self.pos .. self.pos + @as(usize, @intCast(length))];
        self.pos += @as(usize, @intCast(length));
        return result;
    }

    // Helper method for reading text of a specific length (used in extractField)
    pub inline fn readTextOfLength(self: *Decoder, length: u64) CborError![]const u8 {
        if (length > self.config.max_string_length) return CborError.InvalidLength;

        const text_slice = try self.readSlice(@intCast(length));

        // Validate UTF-8 if configured
        if (self.config.validate_utf8) {
            const is_valid = if (self.config.use_simd)
                simd.Simd.validateUtf8(text_slice)
            else
                std.unicode.utf8ValidateSlice(text_slice);

            if (!is_valid) return CborError.InvalidUtf8;
        }

        return text_slice;
    }

    inline fn decodeArray(self: *Decoder, comptime T: type) CborError!T {
        @setEvalBranchQuota(10000);
        const initial = try self.readInitialByte();
        if (initial.major_type != @intFromEnum(MajorType.array)) return CborError.TypeMismatch;
        const length = try self.readLength(initial.additional_info);
        const arr_info = @typeInfo(T).array;
        if (length != arr_info.len) return CborError.InvalidLength;

        var result: T = undefined;
        inline for (&result) |*item| {
            item.* = try self.decodeValue(arr_info.child);
        }
        return result;
    }

    inline fn decodeStruct(self: *Decoder, comptime T: type) CborError!T {
        const initial = try self.readInitialByte();
        if (initial.major_type != @intFromEnum(MajorType.map)) return CborError.TypeMismatch;
        const length = try self.readLength(initial.additional_info);
        const fields = @typeInfo(T).@"struct".fields;
        if (length > self.config.max_collection_size) return CborError.InvalidLength;

        var result: T = undefined;
        var fields_set = [_]bool{false} ** fields.len;

        var i: u64 = 0;
        while (i < length) : (i += 1) {
            const key = try self.decodeText();
            inline for (fields, 0..) |field, idx| {
                if (std.mem.eql(u8, key, field.name)) {
                    @field(result, field.name) = try self.decodeValue(field.type);
                    fields_set[idx] = true;
                    break;
                }
            } else {
                try self.skipValue();
            }
        }

        inline for (fields, 0..) |field, idx| {
            if (!fields_set[idx]) {
                if (@typeInfo(field.type) == .optional) {
                    @field(result, field.name) = null;
                } else {
                    return CborError.TypeMismatch;
                }
            }
        }
        return result;
    }

    inline fn decodeArrayList(self: *Decoder, comptime T: type) CborError!T {
        const initial = try self.readInitialByte();
        if (initial.major_type != @intFromEnum(MajorType.array)) return CborError.TypeMismatch;
        const length = try self.readLength(initial.additional_info);
        if (length > self.config.max_collection_size) return CborError.InvalidLength;

        // Create an ArrayList with default allocator - user should provide allocator
        // This is a basic implementation that requires the ArrayList to be initialized
        var result: T = undefined;

        // Assuming the ArrayList has been properly initialized with an allocator
        // We'll try to resize it to accommodate the items
        if (@hasDecl(T, "resize")) {
            try result.resize(@intCast(length));
        } else if (@hasDecl(T, "ensureTotalCapacity")) {
            try result.ensureTotalCapacity(@intCast(length));
        }

        var i: u64 = 0;
        while (i < length) : (i += 1) {
            const item_type = @TypeOf(result.items[0]);
            const item = try self.decodeValue(item_type);
            if (@hasDecl(T, "append")) {
                try result.append(item);
            } else {
                result.items[i] = item;
            }
        }

        return result;
    }

    pub fn isIndefiniteLength(_: *Decoder, byte: InitialByte) bool {
        return byte.additional_info == INDEFINITE_LENGTH;
    }

    pub fn skipValue(self: *Decoder) CborError!void {
        const initial = try self.readInitialByte();
        switch (initial.major_type) {
            @intFromEnum(MajorType.unsigned_integer), @intFromEnum(MajorType.negative_integer) => {
                _ = try self.readLength(initial.additional_info);
            },
            @intFromEnum(MajorType.byte_string), @intFromEnum(MajorType.text_string) => {
                const length = try self.readLength(initial.additional_info);
                _ = try self.readSlice(@intCast(length));
            },
            @intFromEnum(MajorType.array) => {
                const length = try self.readLength(initial.additional_info);
                var i: u64 = 0;
                while (i < length) : (i += 1) {
                    try self.skipValue();
                }
            },
            @intFromEnum(MajorType.map) => {
                const length = try self.readLength(initial.additional_info);
                var i: u64 = 0;
                while (i < length) : (i += 1) {
                    try self.skipValue();
                    try self.skipValue();
                }
            },
            @intFromEnum(MajorType.float_simple) => {
                switch (initial.additional_info) {
                    20...23 => {}, // Simple values
                    25 => _ = try self.readSlice(2), // f16
                    26 => _ = try self.readSlice(4), // f32
                    27 => _ = try self.readSlice(8), // f64
                    else => return CborError.InvalidFloat,
                }
            },
            else => {}, // All other major types are handled or are invalid
        }
    }

    // Extract a specific field from a CBOR map by name
    pub fn extractField(self: *Decoder, comptime T: type, field_name: []const u8) CborError!?T {
        const original_pos = self.pos;
        defer self.pos = original_pos; // Reset position after extraction attempt

        // First byte must be a map
        const initial = try self.readInitialByte();
        if (initial.major_type != @intFromEnum(MajorType.map)) {
            return CborError.TypeMismatch;
        }

        const len = if (initial.additional_info == INDEFINITE_LENGTH)
            null
        else
            try self.readLength(initial.additional_info);

        var field_count: usize = 0;

        // Search through the map entries
        while (true) {
            // Check if we've reached the end of a definite-length map
            if (len != null and field_count >= len.?) {
                break;
            }

            // Check for break marker in indefinite-length maps
            if (len == null) {
                const peek = try self.peekByte();
                if (peek == BREAK_MARKER) {
                    _ = try self.readByte(); // Consume the break marker
                    break;
                }
            }

            // Read key
            const key_type = try self.readInitialByte();
            // We expect text strings as keys
            if (key_type.major_type != @intFromEnum(MajorType.text_string)) {
                return CborError.TypeMismatch;
            }

            const key_len = try self.readLength(key_type.additional_info);
            const key = try self.readTextOfLength(key_len);

            // If this key matches what we're looking for, read the value and return it
            if (std.mem.eql(u8, key, field_name)) {
                return try self.decodeValueDebug(T);
            } else {
                // Skip the value if it's not what we're looking for
                try self.skipValue();
            }

            field_count += 1;
        }

        // Field not found
        return null;
    }

    // Peek at the next byte without consuming it
    fn peekByte(self: *Decoder) CborError!u8 {
        if (self.stream_reader != null) {
            try self.fillStreamBuffer();
            return self.stream_buffer[self.stream_pos];
        }
        if (self.pos >= self.data.len) {
            return CborError.BufferUnderflow;
        }
        return self.data[self.pos];
    }
};

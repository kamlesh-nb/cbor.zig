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
    stream_buffer: []u8 = &[_]u8{}, // Dynamic buffer
    fallback_buffer: [4096]u8 = undefined, // Fallback for backward compatibility
    stream_pos: usize = 0,
    stream_len: usize = 0,
    allocator: std.mem.Allocator = undefined, // For methods that need allocation
    owns_stream_buffer: bool = false, // Track if we allocated the buffer

    pub fn init(data: []const u8, config: Config) Decoder {
        return .{ .data = data, .pos = 0, .config = config, .depth = 0 };
    }

    pub fn initStreaming(reader: std.io.AnyReader, config: Config) Decoder {
        return Decoder{
            .data = &[_]u8{},
            .pos = 0,
            .config = config,
            .depth = 0,
            .stream_reader = reader,
            // Don't set stream_buffer here - it will be set in fillStreamBuffer
        };
    }

    /// Initialize streaming decoder with estimated size for optimal buffer sizing
    pub fn initStreamingWithEstimate(reader: std.io.AnyReader, config: Config, allocator: std.mem.Allocator, estimated_size: ?usize) !Decoder {
        const buffer_size = config.getStreamBufferSize(estimated_size);

        // If the buffer size fits in our fallback, use it to avoid allocation
        if (buffer_size <= 4096) {
            var decoder = Decoder{
                .data = &[_]u8{},
                .pos = 0,
                .config = config,
                .depth = 0,
                .stream_reader = reader,
                .allocator = allocator,
            };
            decoder.stream_buffer = decoder.fallback_buffer[0..buffer_size];
            return decoder;
        }

        // For larger buffers, allocate dynamically
        const stream_buffer = try allocator.alloc(u8, buffer_size);

        return Decoder{
            .data = &[_]u8{},
            .pos = 0,
            .config = config,
            .depth = 0,
            .stream_reader = reader,
            .stream_buffer = stream_buffer,
            .allocator = allocator,
            .owns_stream_buffer = true,
        };
    }

    /// Clean up allocated resources
    pub fn deinit(self: *Decoder) void {
        if (self.owns_stream_buffer and self.stream_buffer.len > 0) {
            self.allocator.free(self.stream_buffer);
            self.stream_buffer = &[_]u8{};
            self.owns_stream_buffer = false;
        }
    }

    inline fn fillStreamBuffer(self: *Decoder) CborError!void {
        if (self.stream_reader) |reader| {
            // Initialize buffer if not already set
            if (self.stream_buffer.len == 0) {
                const buffer_size = @min(self.config.stream_buffer_size, 4096);
                self.stream_buffer = self.fallback_buffer[0..buffer_size];
            }

            if (self.stream_pos >= self.stream_len) {
                self.stream_len = reader.read(self.stream_buffer) catch return CborError.IoError;
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

            // Ensure we have enough data in the buffer
            while (self.stream_pos + len > self.stream_len) {
                // Calculate how much data is left unread
                const remaining = self.stream_len - self.stream_pos;

                // If we have some unread data, move it to the beginning
                if (remaining > 0) {
                    std.mem.copyForwards(u8, self.stream_buffer[0..remaining], self.stream_buffer[self.stream_pos..self.stream_len]);
                }

                // Update positions
                self.stream_len = remaining;
                self.stream_pos = 0;

                // Read more data to fill the rest of the buffer
                const bytes_read = self.stream_reader.?.read(self.stream_buffer[self.stream_len..]) catch return CborError.IoError;
                if (bytes_read == 0) return CborError.BufferUnderflow; // End of stream
                self.stream_len += bytes_read;
            }

            // Now we can safely return the slice
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
        const initial_byte = try self.peekByte();
        const initial: InitialByte = @bitCast(initial_byte);
        if (initial.major_type == @intFromEnum(MajorType.float_simple) and initial.additional_info == 22) {
            _ = try self.readByte(); // consume the null byte
            return null;
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

    // String decoding that works correctly with streaming by copying data
    pub fn decodeTextStreaming(self: *Decoder, buffer: []u8) CborError![]const u8 {
        const initial = try self.readInitialByte();
        if (initial.major_type != @intFromEnum(MajorType.text_string)) return CborError.TypeMismatch;
        const length = try self.readLength(initial.additional_info);
        if (length > self.config.max_string_length) return CborError.InvalidLength;
        if (length > buffer.len) return CborError.InvalidLength;

        // Read data directly into the provided buffer
        if (self.stream_reader != null) {
            var bytes_read: usize = 0;
            while (bytes_read < length) {
                const remaining = @as(usize, @intCast(length)) - bytes_read;
                const chunk_size = @min(remaining, self.stream_len - self.stream_pos);

                if (chunk_size > 0) {
                    @memcpy(buffer[bytes_read .. bytes_read + chunk_size], self.stream_buffer[self.stream_pos .. self.stream_pos + chunk_size]);
                    self.stream_pos += chunk_size;
                    bytes_read += chunk_size;
                }

                if (bytes_read < length) {
                    try self.fillStreamBuffer();
                }
            }

            const result = buffer[0..@intCast(length)];

            // Validate UTF-8 if configured
            if (self.config.validate_utf8) {
                const is_valid = if (self.config.use_simd)
                    simd.Simd.validateUtf8(result)
                else
                    std.unicode.utf8ValidateSlice(result);

                if (!is_valid) return CborError.InvalidUtf8;
            }

            return result;
        } else {
            // Non-streaming mode
            const text_slice = try self.readSlice(@intCast(length));
            @memcpy(buffer[0..text_slice.len], text_slice);
            return buffer[0..text_slice.len];
        }
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

        if (initial.additional_info != INDEFINITE_LENGTH) {
            if (length != arr_info.len) return CborError.InvalidLength;
        }

        var result: T = undefined;
        if (initial.additional_info == INDEFINITE_LENGTH) {
            var i: usize = 0;
            while (i < arr_info.len) : (i += 1) {
                if (try self.peekByte() == BREAK_MARKER) return CborError.InvalidLength;
                result[i] = try self.decodeValue(arr_info.child);
            }
            if (try self.readByte() != BREAK_MARKER) return CborError.MissingBreakMarker;
        } else {
            // Use regular for loop to avoid stack overflow with large arrays
            for (&result, 0..) |*item, i| {
                _ = i; // suppress unused variable warning
                item.* = try self.decodeValue(arr_info.child);
            }
        }
        return result;
    }

    inline fn decodeStruct(self: *Decoder, comptime T: type) CborError!T {
        const initial = try self.readInitialByte();
        if (initial.major_type != @intFromEnum(MajorType.map)) return CborError.TypeMismatch;
        const length = if (initial.additional_info == INDEFINITE_LENGTH) INDEFINITE_LENGTH else try self.readLength(initial.additional_info);
        const fields = @typeInfo(T).@"struct".fields;
        if (length != INDEFINITE_LENGTH and length > self.config.max_collection_size) return CborError.InvalidLength;

        var result: T = undefined;
        var fields_set = [_]bool{false} ** fields.len;

        // For streaming mode, we need to handle string keys carefully since the buffer can be overwritten
        var key_buffer: [256]u8 = undefined; // Buffer for copying keys in streaming mode

        if (length == INDEFINITE_LENGTH) {
            while (try self.peekByte() != BREAK_MARKER) {
                const key = if (self.stream_reader != null)
                    try self.decodeTextStreaming(&key_buffer)
                else
                    try self.decodeText();

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
            _ = try self.readByte(); // consume break marker
        } else {
            var i: u64 = 0;
            while (i < length) : (i += 1) {
                const key = if (self.stream_reader != null)
                    try self.decodeTextStreaming(&key_buffer)
                else
                    try self.decodeText();

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
                return try self.decodeValue(T);
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

    // Helper to decode text that copies data in streaming mode
    pub fn decodeTextCopy(self: *Decoder, allocator: std.mem.Allocator) CborError![]const u8 {
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

        // For streaming mode, copy the data to avoid buffer overwrite issues
        if (self.stream_reader != null) {
            return allocator.dupe(u8, text_slice) catch return CborError.OutOfMemory;
        }

        return text_slice;
    }
};

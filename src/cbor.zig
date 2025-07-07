const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const MajorType = enum(u3) {
    unsigned_integer = 0,
    negative_integer = 1,
    byte_string = 2,
    text_string = 3,
    array = 4,
    map = 5,
    tag = 6,
    float_simple = 7,
};

pub const SimpleValue = enum(u8) {
    false = 20,
    true = 21,
    null = 22,
    undefined = 23,
};

pub const BREAK_STOP_CODE: u8 = 0xFF;

pub const CborError = error{
    UnexpectedEndOfInput,
    InvalidAdditionalInfo,
    UnexpectedMajorType,
    TypeMismatch,
    FloatTypeMismatch,
    IntegerOverflow,
    NegativeIntegerForUnsigned,
    MissingRequiredField,
    InvalidBooleanValue,
    InvalidFloatAdditionalInfo,
    ExpectedNull,
    UnsupportedOptionalType,
    CollectionTooLarge,
    StringTooLong,
    OutOfMemory,
};

pub const Config = struct {
    max_collection_size: u64 = 1 << 20,
    max_string_length: u64 = 1 << 16,
    max_depth: u32 = 64,
};

const InitialByte = struct {
    major_type: MajorType,
    additional_info: u5,
};

pub const Encoder = struct {
    writer: std.io.AnyWriter,
    config: Config,

    pub fn init(writer: std.io.AnyWriter) Encoder {
        return Encoder{
            .writer = writer,
            .config = Config{},
        };
    }

    fn initWithConfig(writer: std.io.AnyWriter, config: Config) Encoder {
        return Encoder{
            .writer = writer,
            .config = config,
        };
    }

    pub fn encode(self: *Encoder, value: anytype) (CborError || @TypeOf(self.writer).Error)!void {
        return self.encodeWithDepth(value, 0);
    }

    fn encodeWithDepth(self: *Encoder, value: anytype, depth: u32) (CborError || @TypeOf(self.writer).Error)!void {
        if (depth > self.config.max_depth) return CborError.CollectionTooLarge;

        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        switch (type_info) {
            .int => try self.encodeInt(value),
            .float => try self.encodeFloat(value),
            .bool => try self.encodeBool(value),
            .optional => try self.encodeOptionalWithDepth(value, depth),
            .pointer => |ptr_info| {
                switch (ptr_info.size) {
                    .slice => {
                        if (ptr_info.child == u8) {
                            try self.encodeText(value);
                        } else {
                            try self.encodeArrayWithDepth(value, depth);
                        }
                    },
                    .many => {
                        if (ptr_info.child == u8) {
                            const len = std.mem.len(@as([*:0]const u8, @ptrCast(value)));
                            const slice = value[0..len];
                            try self.encodeText(slice);
                        } else {
                            try self.encodeWithDepth(value.*, depth);
                        }
                    },
                    .one => {
                        if (ptr_info.child == u8 or
                            (@typeInfo(ptr_info.child) == .array and
                                @typeInfo(ptr_info.child).array.child == u8))
                        {
                            const array_info = @typeInfo(ptr_info.child);
                            if (array_info == .array) {
                                const len = array_info.array.len;
                                const slice = value[0..len];
                                try self.encodeText(slice);
                            } else {
                                try self.encodeWithDepth(value.*, depth);
                            }
                        } else {
                            try self.encodeWithDepth(value.*, depth);
                        }
                    },
                    .c => @compileError("C pointers not supported"),
                }
            },
            .array => try self.encodeArrayWithDepth(value, depth),
            .@"struct" => |struct_info| {
                // Check if this is an ArrayList by looking at its fields
                const is_arraylist = comptime blk: {
                    if (struct_info.fields.len < 2) break :blk false;
                    var has_items = false;
                    var has_capacity = false;
                    var has_allocator = false;

                    for (struct_info.fields) |field| {
                        if (std.mem.eql(u8, field.name, "items")) has_items = true;
                        if (std.mem.eql(u8, field.name, "capacity")) has_capacity = true;
                        if (std.mem.eql(u8, field.name, "allocator")) has_allocator = true;
                    }

                    break :blk has_items and has_capacity and has_allocator;
                };

                if (is_arraylist) {
                    try self.encodeArrayWithDepth(value.items, depth);
                } else {
                    try self.encodeStructWithDepth(value, depth);
                }
            },
            .void => try self.encodeNull(),
            else => @compileError("Unsupported type: " ++ @typeName(T)),
        }
    }

    fn writeInitialByte(self: *Encoder, major_type: MajorType, additional_info: u5) !void {
        const byte = (@as(u8, @intFromEnum(major_type)) << 5) | additional_info;
        try self.writer.writeByte(byte);
    }

    pub fn encodeLength(self: *Encoder, major_type: MajorType, length: u64) !void {
        if (length < 24) {
            try self.writeInitialByte(major_type, @intCast(length));
        } else if (length <= 0xFF) {
            try self.writeInitialByte(major_type, 24);
            try self.writer.writeByte(@intCast(length));
        } else if (length <= 0xFFFF) {
            try self.writeInitialByte(major_type, 25);
            try self.writer.writeInt(u16, @intCast(length), .big);
        } else if (length <= 0xFFFFFFFF) {
            try self.writeInitialByte(major_type, 26);
            try self.writer.writeInt(u32, @intCast(length), .big);
        } else {
            try self.writeInitialByte(major_type, 27);
            try self.writer.writeInt(u64, length, .big);
        }
    }

    fn encodeInt(self: *Encoder, value: anytype) !void {
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        switch (type_info.int.signedness) {
            .unsigned => {
                try self.encodeLength(.unsigned_integer, value);
            },
            .signed => {
                if (value < 0) {
                    const positive = @as(u64, @intCast(-(value + 1)));
                    try self.encodeLength(.negative_integer, positive);
                } else {
                    try self.encodeLength(.unsigned_integer, @intCast(value));
                }
            },
        }
    }

    fn encodeFloat(self: *Encoder, value: anytype) !void {
        const T = @TypeOf(value);

        switch (T) {
            f16 => {
                try self.writeInitialByte(.float_simple, 25);
                try self.writer.writeInt(u16, @bitCast(value), .big);
            },
            f32 => {
                try self.writeInitialByte(.float_simple, 26);
                try self.writer.writeInt(u32, @bitCast(value), .big);
            },
            f64 => {
                try self.writeInitialByte(.float_simple, 27);
                try self.writer.writeInt(u64, @bitCast(value), .big);
            },
            else => @compileError("Unsupported float type: " ++ @typeName(T)),
        }
    }

    fn encodeBool(self: *Encoder, value: bool) !void {
        const simple_value: u5 = if (value) 21 else 20;
        try self.writeInitialByte(.float_simple, simple_value);
    }

    fn encodeNull(self: *Encoder) !void {
        try self.writeInitialByte(.float_simple, 22);
    }

    fn encodeOptionalWithDepth(self: *Encoder, value: anytype, depth: u32) (CborError || @TypeOf(self.writer).Error)!void {
        if (value) |val| {
            try self.encodeWithDepth(val, depth + 1);
        } else {
            try self.encodeNull();
        }
    }

    fn encodeBytes(self: *Encoder, bytes: []const u8) !void {
        if (bytes.len > self.config.max_string_length) return CborError.StringTooLong;
        try self.encodeLength(.byte_string, bytes.len);
        try self.writer.writeAll(bytes);
    }

    pub fn encodeText(self: *Encoder, text: []const u8) !void {
        if (text.len > self.config.max_string_length) return CborError.StringTooLong;
        try self.encodeLength(.text_string, text.len);
        try self.writer.writeAll(text);
    }

    fn encodeArrayWithDepth(self: *Encoder, array: anytype, depth: u32) (CborError || @TypeOf(self.writer).Error)!void {
        if (array.len > self.config.max_collection_size) return CborError.CollectionTooLarge;
        try self.encodeLength(.array, array.len);
        for (array) |item| {
            try self.encodeWithDepth(item, depth + 1);
        }
    }

    fn encodeStructWithDepth(self: *Encoder, value: anytype, depth: u32) (CborError || @TypeOf(self.writer).Error)!void {
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);
        const fields = type_info.@"struct".fields;

        try self.encodeLength(.map, fields.len);

        inline for (fields) |field| {
            try self.encodeText(field.name);
            try self.encodeWithDepth(@field(value, field.name), depth + 1);
        }
    }

    pub fn encodeIndefiniteArray(self: *Encoder, items: anytype) (CborError || @TypeOf(self.writer).Error)!void {
        return self.encodeIndefiniteArrayWithDepth(items, 0);
    }

    fn encodeIndefiniteArrayWithDepth(self: *Encoder, items: anytype, depth: u32) (CborError || @TypeOf(self.writer).Error)!void {
        if (depth > self.config.max_depth) return CborError.CollectionTooLarge;

        try self.writeInitialByte(.array, 31);

        for (items) |item| {
            try self.encodeWithDepth(item, depth + 1);
        }

        try self.writer.writeByte(BREAK_STOP_CODE);
    }

    pub fn encodeIndefiniteMap(self: *Encoder, value: anytype) (CborError || @TypeOf(self.writer).Error)!void {
        return self.encodeIndefiniteMapWithDepth(value, 0);
    }

    fn encodeIndefiniteMapWithDepth(self: *Encoder, value: anytype, depth: u32) (CborError || @TypeOf(self.writer).Error)!void {
        if (depth > self.config.max_depth) return CborError.CollectionTooLarge;

        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        switch (type_info) {
            .@"struct" => {
                const fields = type_info.@"struct".fields;

                try self.writeInitialByte(.map, 31);

                inline for (fields) |field| {
                    try self.encodeText(field.name);
                    try self.encodeWithDepth(@field(value, field.name), depth + 1);
                }

                try self.writer.writeByte(BREAK_STOP_CODE);
            },
            else => @compileError("Indefinite maps only supported for structs"),
        }
    }
};

pub const Decoder = struct {
    reader: std.io.AnyReader,
    allocator: Allocator,
    config: Config,

    pub fn init(reader: std.io.AnyReader, allocator: Allocator) Decoder {
        return Decoder{
            .reader = reader,
            .allocator = allocator,
            .config = Config{},
        };
    }

    fn initWithConfig(reader: std.io.AnyReader, allocator: Allocator, config: Config) Decoder {
        return Decoder{
            .reader = reader,
            .allocator = allocator,
            .config = config,
        };
    }

    fn decode(self: *Decoder, comptime T: type) (CborError || Allocator.Error || @TypeOf(self.reader).Error)!T {
        return self.decodeWithDepth(T, 0);
    }

    fn decodeWithDepth(self: *Decoder, comptime T: type, depth: u32) (CborError || Allocator.Error || @TypeOf(self.reader).Error)!T {
        if (depth > self.config.max_depth) return CborError.CollectionTooLarge;

        const type_info = @typeInfo(T);

        switch (type_info) {
            .int => return self.decodeInt(T),
            .float => return self.decodeFloat(T),
            .bool => return self.decodeBool(),
            .optional => return self.decodeOptionalWithDepth(T, depth),
            .pointer => |ptr_info| {
                switch (ptr_info.size) {
                    .slice => {
                        if (ptr_info.child == u8) {
                            return self.decodeText();
                        } else {
                            return self.decodeArrayWithDepth(T, depth);
                        }
                    },
                    else => @compileError("Unsupported pointer type"),
                }
            },
            .array => return self.decodeArrayWithDepth(T, depth),
            .@"struct" => |struct_info| {
                const is_arraylist = comptime blk: {
                    if (struct_info.fields.len < 2) break :blk false;
                    var has_items = false;
                    var has_capacity = false;
                    var has_allocator = false;

                    for (struct_info.fields) |field| {
                        if (std.mem.eql(u8, field.name, "items")) has_items = true;
                        if (std.mem.eql(u8, field.name, "capacity")) has_capacity = true;
                        if (std.mem.eql(u8, field.name, "allocator")) has_allocator = true;
                    }

                    break :blk has_items and has_capacity and has_allocator;
                };

                if (is_arraylist) {
                    return self.decodeArrayList(T, depth);
                } else {
                    return self.decodeStructWithDepth(T, depth);
                }
            },
            .void => {
                try self.expectNull();
                return {};
            },
            else => @compileError("Unsupported type: " ++ @typeName(T)),
        }
    }

    fn readInitialByte(self: *Decoder) !InitialByte {
        const byte = self.reader.readByte() catch return CborError.UnexpectedEndOfInput;
        const major_type = @as(MajorType, @enumFromInt(byte >> 5));
        const additional_info = @as(u5, @intCast(byte & 0x1F));
        return InitialByte{ .major_type = major_type, .additional_info = additional_info };
    }

    fn readLength(self: *Decoder, additional_info: u5) !u64 {
        return switch (additional_info) {
            0...23 => additional_info,
            24 => self.reader.readByte() catch return CborError.UnexpectedEndOfInput,
            25 => self.reader.readInt(u16, .big) catch return CborError.UnexpectedEndOfInput,
            26 => self.reader.readInt(u32, .big) catch return CborError.UnexpectedEndOfInput,
            27 => self.reader.readInt(u64, .big) catch return CborError.UnexpectedEndOfInput,
            31 => return CborError.InvalidAdditionalInfo,
            else => CborError.InvalidAdditionalInfo,
        };
    }

    fn validateLength(self: *Decoder, length: u64) !void {
        if (length > self.config.max_collection_size) {
            return CborError.CollectionTooLarge;
        }
    }

    fn validateStringLength(self: *Decoder, length: u64) !void {
        if (length > self.config.max_string_length) {
            return CborError.StringTooLong;
        }
    }

    fn skipValue(self: *Decoder) (CborError || @TypeOf(self.reader).Error)!void {
        const initial = try self.readInitialByte();
        try self.skipValueFromInitial(initial);
    }

    fn skipValueFromInitial(self: *Decoder, initial: InitialByte) (CborError || @TypeOf(self.reader).Error)!void {
        switch (initial.major_type) {
            .unsigned_integer, .negative_integer => {
                if (initial.additional_info == 31) return CborError.InvalidAdditionalInfo;
                _ = try self.readLength(initial.additional_info);
            },
            .byte_string, .text_string => {
                if (initial.additional_info == 31) {
                    while (true) {
                        const peek_byte = self.reader.readByte() catch return CborError.UnexpectedEndOfInput;
                        if (peek_byte == BREAK_STOP_CODE) break;

                        // Skip the chunk
                        const chunk_major = @as(MajorType, @enumFromInt(peek_byte >> 5));
                        const chunk_additional = @as(u5, @intCast(peek_byte & 0x1F));
                        if (chunk_major != initial.major_type) return CborError.UnexpectedMajorType;

                        const chunk_length = try self.readLength(chunk_additional);
                        try self.reader.skipBytes(chunk_length, .{});
                    }
                } else {
                    const length = try self.readLength(initial.additional_info);
                    try self.reader.skipBytes(length, .{});
                }
            },
            .array => {
                if (initial.additional_info == 31) {
                    while (true) {
                        const peek_byte = self.reader.readByte() catch return CborError.UnexpectedEndOfInput;
                        if (peek_byte == BREAK_STOP_CODE) break;

                        // Skip the item
                        const item_major = @as(MajorType, @enumFromInt(peek_byte >> 5));
                        const item_additional = @as(u5, @intCast(peek_byte & 0x1F));
                        const item_initial = InitialByte{ .major_type = item_major, .additional_info = item_additional };
                        try self.skipValueFromInitial(item_initial);
                    }
                } else {
                    const length = try self.readLength(initial.additional_info);
                    var i: u64 = 0;
                    while (i < length) : (i += 1) {
                        try self.skipValue();
                    }
                }
            },
            .map => {
                if (initial.additional_info == 31) {
                    // Indefinite-length map, skip key-value pairs until break
                    while (true) {
                        const peek_byte = self.reader.readByte() catch return CborError.UnexpectedEndOfInput;
                        if (peek_byte == BREAK_STOP_CODE) break;

                        // Skip key
                        const key_major = @as(MajorType, @enumFromInt(peek_byte >> 5));
                        const key_additional = @as(u5, @intCast(peek_byte & 0x1F));
                        const key_initial = InitialByte{ .major_type = key_major, .additional_info = key_additional };
                        try self.skipValueFromInitial(key_initial);

                        // Skip value
                        try self.skipValue();
                    }
                } else {
                    const length = try self.readLength(initial.additional_info);
                    var i: u64 = 0;
                    while (i < length) : (i += 1) {
                        try self.skipValue(); // key
                        try self.skipValue(); // value
                    }
                }
            },
            .float_simple => {
                switch (initial.additional_info) {
                    0...23 => {}, // Simple values
                    25 => try self.reader.skipBytes(2, .{}), // f16
                    26 => try self.reader.skipBytes(4, .{}), // f32
                    27 => try self.reader.skipBytes(8, .{}), // f64
                    31 => return CborError.InvalidAdditionalInfo, // "break" is not valid here when called directly
                    else => return CborError.InvalidAdditionalInfo,
                }
            },
            .tag => {
                if (initial.additional_info == 31) return CborError.InvalidAdditionalInfo;
                _ = try self.readLength(initial.additional_info);
                try self.skipValue();
            },
        }
    }

    fn decodeInt(self: *Decoder, comptime T: type) !T {
        const initial = try self.readInitialByte();
        const length = try self.readLength(initial.additional_info);

        switch (initial.major_type) {
            .unsigned_integer => {
                if (length > std.math.maxInt(T)) return CborError.IntegerOverflow;
                return @intCast(length);
            },
            .negative_integer => {
                const type_info = @typeInfo(T);
                if (type_info.int.signedness == .unsigned) return CborError.NegativeIntegerForUnsigned;

                const positive = length + 1;

                // Special handling for minimum values that might overflow
                switch (T) {
                    i8 => {
                        if (positive > 128) return CborError.IntegerOverflow;
                        if (positive == 128) return std.math.minInt(i8);
                        return -@as(i8, @intCast(positive));
                    },
                    i16 => {
                        if (positive > 32768) return CborError.IntegerOverflow;
                        if (positive == 32768) return std.math.minInt(i16);
                        return -@as(i16, @intCast(positive));
                    },
                    i32 => {
                        if (positive > 2147483648) return CborError.IntegerOverflow;
                        if (positive == 2147483648) return std.math.minInt(i32);
                        return -@as(i32, @intCast(positive));
                    },
                    i64 => {
                        if (positive > 9223372036854775808) return CborError.IntegerOverflow;
                        if (positive == 9223372036854775808) return std.math.minInt(i64);
                        return -@as(i64, @intCast(positive));
                    },
                    else => {
                        // Generic fallback
                        const abs_min = @as(u64, @intCast(@abs(std.math.minInt(T))));
                        if (positive > abs_min) return CborError.IntegerOverflow;
                        return -@as(T, @intCast(positive));
                    },
                }
            },
            else => return CborError.UnexpectedMajorType,
        }
    }

    fn decodeFloat(self: *Decoder, comptime T: type) !T {
        const initial = try self.readInitialByte();

        if (initial.major_type != .float_simple) return CborError.UnexpectedMajorType;

        return switch (initial.additional_info) {
            25 => blk: {
                if (T != f16) return CborError.FloatTypeMismatch;
                const bits = self.reader.readInt(u16, .big) catch return CborError.UnexpectedEndOfInput;
                break :blk @bitCast(bits);
            },
            26 => blk: {
                if (T != f32) return CborError.FloatTypeMismatch;
                const bits = self.reader.readInt(u32, .big) catch return CborError.UnexpectedEndOfInput;
                break :blk @bitCast(bits);
            },
            27 => blk: {
                if (T != f64) return CborError.FloatTypeMismatch;
                const bits = self.reader.readInt(u64, .big) catch return CborError.UnexpectedEndOfInput;
                break :blk @bitCast(bits);
            },
            else => CborError.InvalidFloatAdditionalInfo,
        };
    }

    fn decodeBool(self: *Decoder) !bool {
        const initial = try self.readInitialByte();

        if (initial.major_type != .float_simple) return CborError.UnexpectedMajorType;

        return switch (initial.additional_info) {
            20 => false,
            21 => true,
            else => CborError.InvalidBooleanValue,
        };
    }

    fn expectNull(self: *Decoder) !void {
        const initial = try self.readInitialByte();

        if (initial.major_type != .float_simple or initial.additional_info != 22) {
            return CborError.ExpectedNull;
        }
    }

    fn decodeOptionalWithDepth(self: *Decoder, comptime T: type, depth: u32) (CborError || Allocator.Error || @TypeOf(self.reader).Error)!T {
        const type_info = @typeInfo(T);
        const ChildType = type_info.optional.child;

        const initial = try self.readInitialByte();

        if (initial.major_type == .float_simple and initial.additional_info == 22) {
            return null;
        }

        return try self.decodeValueFromInitial(ChildType, initial, depth + 1);
    }

    fn decodeValueFromInitial(self: *Decoder, comptime T: type, initial: InitialByte, depth: u32) (CborError || Allocator.Error || @TypeOf(self.reader).Error)!T {
        const type_info = @typeInfo(T);

        switch (type_info) {
            .int => {
                const length = try self.readLength(initial.additional_info);
                switch (initial.major_type) {
                    .unsigned_integer => {
                        if (length > std.math.maxInt(T)) return CborError.IntegerOverflow;
                        return @intCast(length);
                    },
                    .negative_integer => {
                        if (type_info.int.signedness == .unsigned) return CborError.NegativeIntegerForUnsigned;
                        const positive = length + 1;
                        if (positive > @abs(std.math.minInt(T))) return CborError.IntegerOverflow;
                        return -@as(T, @intCast(positive));
                    },
                    else => return CborError.UnexpectedMajorType,
                }
            },
            .bool => {
                if (initial.major_type != .float_simple) return CborError.UnexpectedMajorType;
                return switch (initial.additional_info) {
                    20 => false,
                    21 => true,
                    else => CborError.InvalidBooleanValue,
                };
            },
            .float => {
                if (initial.major_type != .float_simple) return CborError.UnexpectedMajorType;
                return switch (initial.additional_info) {
                    25 => blk: {
                        if (T != f16) return CborError.FloatTypeMismatch;
                        const bits = self.reader.readInt(u16, .big) catch return CborError.UnexpectedEndOfInput;
                        break :blk @bitCast(bits);
                    },
                    26 => blk: {
                        if (T != f32) return CborError.FloatTypeMismatch;
                        const bits = self.reader.readInt(u32, .big) catch return CborError.UnexpectedEndOfInput;
                        break :blk @bitCast(bits);
                    },
                    27 => blk: {
                        if (T != f64) return CborError.FloatTypeMismatch;
                        const bits = self.reader.readInt(u64, .big) catch return CborError.UnexpectedEndOfInput;
                        break :blk @bitCast(bits);
                    },
                    else => CborError.InvalidFloatAdditionalInfo,
                };
            },
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    if (initial.major_type != .text_string) return CborError.UnexpectedMajorType;
                    const length = try self.readLength(initial.additional_info);
                    try self.validateStringLength(length);
                    const text = try self.allocator.alloc(u8, length);
                    errdefer self.allocator.free(text);
                    self.reader.readNoEof(text) catch return CborError.UnexpectedEndOfInput;
                    return text;
                } else {
                    // For other pointer types (arrays), decode using the initial byte
                    return self.decodeArrayFromInitial(T, initial, depth);
                }
            },
            .array => {
                return self.decodeArrayFromInitial(T, initial, depth);
            },
            .@"struct" => {
                return self.decodeStructFromInitial(T, initial, depth);
            },
            .optional => {
                if (initial.major_type == .float_simple and initial.additional_info == 22) {
                    return null;
                } else {
                    const child_type = type_info.optional.child;
                    const value = try self.decodeValueFromInitial(child_type, initial, depth);
                    return value;
                }
            },
            .void => {
                if (initial.major_type != .float_simple or initial.additional_info != 22) {
                    return CborError.ExpectedNull;
                }
                return {};
            },
            else => return CborError.TypeMismatch,
        }
    }

    fn decodeArrayFromInitial(self: *Decoder, comptime T: type, initial: InitialByte, depth: u32) (CborError || Allocator.Error || @TypeOf(self.reader).Error)!T {
        const type_info = @typeInfo(T);

        if (initial.major_type != .array) return CborError.UnexpectedMajorType;

        const length = try self.readLength(initial.additional_info);
        try self.validateLength(length);

        switch (type_info) {
            .pointer => |ptr_info| {
                switch (ptr_info.size) {
                    .slice => {
                        const ChildType = ptr_info.child;
                        const array = try self.allocator.alloc(ChildType, length);
                        errdefer self.allocator.free(array);

                        for (array, 0..) |*item, i| {
                            _ = i;
                            item.* = try self.decodeWithDepth(ChildType, depth + 1);
                        }

                        return array;
                    },
                    else => @compileError("Unsupported pointer type for arrays"),
                }
            },
            .array => |arr_info| {
                if (length != arr_info.len) return CborError.CollectionTooLarge;

                var result: T = undefined;
                for (&result, 0..) |*item, i| {
                    _ = i;
                    item.* = try self.decodeWithDepth(arr_info.child, depth + 1);
                }
                return result;
            },
            else => @compileError("Unsupported array type"),
        }
    }

    fn decodeStructFromInitial(self: *Decoder, comptime T: type, initial: InitialByte, depth: u32) (CborError || Allocator.Error || @TypeOf(self.reader).Error)!T {
        const type_info = @typeInfo(T);
        const fields = type_info.@"struct".fields;

        if (initial.major_type != .map) return CborError.UnexpectedMajorType;

        const length = try self.readLength(initial.additional_info);
        try self.validateLength(length);

        var result: T = undefined;
        var fields_set = [_]bool{false} ** fields.len;
        var allocated_fields = [_]bool{false} ** fields.len;

        var i: u64 = 0;
        while (i < length) : (i += 1) {
            const key = try self.decodeText();
            defer self.allocator.free(key);

            var found = false;
            inline for (fields, 0..) |field, field_idx| {
                if (std.mem.eql(u8, key, field.name)) {
                    @field(result, field.name) = self.decodeWithDepth(field.type, depth + 1) catch |err| {
                        // Clean up any fields that were already allocated
                        inline for (fields, 0..) |cleanup_field, cleanup_idx| {
                            if (allocated_fields[cleanup_idx]) {
                                const field_type_info = @typeInfo(cleanup_field.type);
                                if (field_type_info == .pointer and field_type_info.pointer.size == .slice and field_type_info.pointer.child == u8) {
                                    self.allocator.free(@field(result, cleanup_field.name));
                                }
                                // Add more cleanup for other allocating types as needed
                            }
                        }
                        return err;
                    };
                    fields_set[field_idx] = true;
                    // Mark fields that allocate memory
                    const field_type_info = @typeInfo(field.type);
                    if (field_type_info == .pointer and field_type_info.pointer.size == .slice) {
                        allocated_fields[field_idx] = true;
                    }
                    found = true;
                    break;
                }
            }

            if (!found) {
                // Skip unknown field
                try self.skipValue();
            }
        }

        // Check that all required fields were set
        inline for (fields, 0..) |field, field_idx| {
            if (!fields_set[field_idx]) {
                if (@typeInfo(field.type) == .optional) {
                    @field(result, field.name) = null;
                } else {
                    // Clean up any fields that were already allocated before returning error
                    inline for (fields, 0..) |cleanup_field, cleanup_idx| {
                        if (allocated_fields[cleanup_idx]) {
                            const field_type_info = @typeInfo(cleanup_field.type);
                            if (field_type_info == .pointer and field_type_info.pointer.size == .slice and field_type_info.pointer.child == u8) {
                                self.allocator.free(@field(result, cleanup_field.name));
                            }
                        }
                    }
                    return CborError.MissingRequiredField;
                }
            }
        }

        return result;
    }

    fn decodeBytes(self: *Decoder) ![]u8 {
        const initial = try self.readInitialByte();

        if (initial.major_type != .byte_string) return CborError.UnexpectedMajorType;

        const length = try self.readLength(initial.additional_info);
        try self.validateStringLength(length);
        const bytes = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(bytes);

        self.reader.readNoEof(bytes) catch return CborError.UnexpectedEndOfInput;
        return bytes;
    }

    fn decodeText(self: *Decoder) ![]u8 {
        const initial = try self.readInitialByte();

        if (initial.major_type != .text_string) return CborError.UnexpectedMajorType;

        const length = try self.readLength(initial.additional_info);
        try self.validateStringLength(length);
        const text = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(text);

        self.reader.readNoEof(text) catch return CborError.UnexpectedEndOfInput;
        return text;
    }

    fn decodeArrayWithDepth(self: *Decoder, comptime T: type, depth: u32) (CborError || Allocator.Error || @TypeOf(self.reader).Error)!T {
        const type_info = @typeInfo(T);

        const initial = try self.readInitialByte();
        if (initial.major_type != .array) return CborError.UnexpectedMajorType;

        const length = try self.readLength(initial.additional_info);
        try self.validateLength(length);

        switch (type_info) {
            .pointer => |ptr_info| {
                switch (ptr_info.size) {
                    .slice => {
                        const ChildType = ptr_info.child;
                        const array = try self.allocator.alloc(ChildType, length);
                        errdefer self.allocator.free(array);

                        for (array, 0..) |*item, i| {
                            _ = i;
                            item.* = try self.decodeWithDepth(ChildType, depth + 1);
                        }

                        return array;
                    },
                    else => @compileError("Unsupported pointer type for arrays"),
                }
            },
            .array => |arr_info| {
                if (length != arr_info.len) return CborError.CollectionTooLarge;

                var result: T = undefined;
                for (&result, 0..) |*item, i| {
                    _ = i;
                    item.* = try self.decodeWithDepth(arr_info.child, depth + 1);
                }
                return result;
            },
            else => @compileError("Unsupported array type"),
        }
    }

    fn decodeStructWithDepth(self: *Decoder, comptime T: type, depth: u32) (CborError || Allocator.Error || @TypeOf(self.reader).Error)!T {
        const type_info = @typeInfo(T);
        const fields = type_info.@"struct".fields;

        const initial = try self.readInitialByte();
        if (initial.major_type != .map) return CborError.UnexpectedMajorType;

        const length = try self.readLength(initial.additional_info);
        try self.validateLength(length);

        var result: T = undefined;
        var fields_set = [_]bool{false} ** fields.len;
        var allocated_fields = [_]bool{false} ** fields.len;

        var i: u64 = 0;
        while (i < length) : (i += 1) {
            const key = try self.decodeText();
            defer self.allocator.free(key);

            var found = false;
            inline for (fields, 0..) |field, field_idx| {
                if (std.mem.eql(u8, key, field.name)) {
                    @field(result, field.name) = self.decodeWithDepth(field.type, depth + 1) catch |err| {
                        // Clean up any fields that were already allocated
                        inline for (fields, 0..) |cleanup_field, cleanup_idx| {
                            if (allocated_fields[cleanup_idx]) {
                                const field_type_info = @typeInfo(cleanup_field.type);
                                if (field_type_info == .pointer and field_type_info.pointer.size == .slice and field_type_info.pointer.child == u8) {
                                    self.allocator.free(@field(result, cleanup_field.name));
                                }
                                // Add more cleanup for other allocating types as needed
                            }
                        }
                        return err;
                    };
                    fields_set[field_idx] = true;
                    // Mark fields that allocate memory
                    const field_type_info = @typeInfo(field.type);
                    if (field_type_info == .pointer and field_type_info.pointer.size == .slice) {
                        allocated_fields[field_idx] = true;
                    }
                    found = true;
                    break;
                }
            }

            if (!found) {
                // Skip unknown field
                try self.skipValue();
            }
        }

        // Check that all required fields were set
        inline for (fields, 0..) |field, field_idx| {
            if (!fields_set[field_idx]) {
                if (@typeInfo(field.type) == .optional) {
                    @field(result, field.name) = null;
                } else {
                    // Clean up any fields that were already allocated before returning error
                    inline for (fields, 0..) |cleanup_field, cleanup_idx| {
                        if (allocated_fields[cleanup_idx]) {
                            const field_type_info = @typeInfo(cleanup_field.type);
                            if (field_type_info == .pointer and field_type_info.pointer.size == .slice and field_type_info.pointer.child == u8) {
                                self.allocator.free(@field(result, cleanup_field.name));
                            }
                        }
                    }
                    return CborError.MissingRequiredField;
                }
            }
        }

        return result;
    }

    fn decodeArrayList(self: *Decoder, comptime T: type, depth: u32) (CborError || Allocator.Error || @TypeOf(self.reader).Error)!T {
        const initial = try self.readInitialByte();
        if (initial.major_type != .array) return CborError.UnexpectedMajorType;

        // Extract the child type from ArrayList
        const type_info = @typeInfo(T);
        if (type_info != .@"struct") return CborError.TypeMismatch;

        // Get the child type - we need to inspect the ArrayList's items field
        const ChildType = @typeInfo(@TypeOf(@as(T, undefined).items)).pointer.child;

        if (initial.additional_info == 31) {
            // Indefinite-length array
            var result = T.init(self.allocator);
            errdefer result.deinit();

            while (true) {
                // Check for break stop code
                const peek_byte = self.reader.readByte() catch return CborError.UnexpectedEndOfInput;
                if (peek_byte == BREAK_STOP_CODE) break;

                // Put the byte back by creating a new initial byte
                const major_type = @as(MajorType, @enumFromInt(peek_byte >> 5));
                const additional_info = @as(u5, @intCast(peek_byte & 0x1F));
                const restored_initial = InitialByte{ .major_type = major_type, .additional_info = additional_info };

                // Decode the item
                const item = try self.decodeValueFromInitial(ChildType, restored_initial, depth + 1);
                try result.append(item);

                if (result.items.len > self.config.max_collection_size) {
                    return CborError.CollectionTooLarge;
                }
            }

            return result;
        } else {
            // Definite-length array
            const length = try self.readLength(initial.additional_info);
            try self.validateLength(length);

            var result = T.init(self.allocator);
            errdefer result.deinit();

            var i: u64 = 0;
            while (i < length) : (i += 1) {
                const item = try self.decodeWithDepth(ChildType, depth + 1);
                try result.append(item);
            }

            return result;
        }
    }

    pub fn decodeIndefiniteArray(self: *Decoder, comptime T: type) (CborError || Allocator.Error || @TypeOf(self.reader).Error)![]T {
        return self.decodeIndefiniteArrayWithDepth(T, 0);
    }

    fn decodeIndefiniteArrayWithDepth(self: *Decoder, comptime T: type, depth: u32) (CborError || Allocator.Error || @TypeOf(self.reader).Error)![]T {
        if (depth > self.config.max_depth) return CborError.CollectionTooLarge;

        const initial = try self.readInitialByte();
        if (initial.major_type != .array) return CborError.UnexpectedMajorType;
        if (initial.additional_info != 31) return CborError.UnexpectedMajorType; // Not indefinite

        var items = ArrayList(T).init(self.allocator);
        errdefer {
            // Clean up allocated items on error
            for (items.items) |item| {
                if (@typeInfo(T) == .pointer) {
                    const ptr_info = @typeInfo(T).pointer;
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        self.allocator.free(item);
                    }
                }
            }
            items.deinit();
        }

        while (true) {
            // Check for break stop code
            const peek_byte = self.reader.readByte() catch return CborError.UnexpectedEndOfInput;
            if (peek_byte == BREAK_STOP_CODE) {
                break;
            }

            // Put the byte back by creating a new initial byte
            const major_type = @as(MajorType, @enumFromInt(peek_byte >> 5));
            const additional_info = @as(u5, @intCast(peek_byte & 0x1F));
            const restored_initial = InitialByte{ .major_type = major_type, .additional_info = additional_info };

            // Decode the item
            const item = try self.decodeValueFromInitial(T, restored_initial, depth + 1);
            try items.append(item);

            if (items.items.len > self.config.max_collection_size) {
                return CborError.CollectionTooLarge;
            }
        }

        return items.toOwnedSlice();
    }

    pub fn decodeIndefiniteMap(self: *Decoder, comptime T: type) (CborError || Allocator.Error || @TypeOf(self.reader).Error)!T {
        return self.decodeIndefiniteMapWithDepth(T, 0);
    }

    fn decodeIndefiniteMapWithDepth(self: *Decoder, comptime T: type, depth: u32) (CborError || Allocator.Error || @TypeOf(self.reader).Error)!T {
        if (depth > self.config.max_depth) return CborError.CollectionTooLarge;

        const type_info = @typeInfo(T);
        if (type_info != .@"struct") {
            @compileError("Indefinite maps can only be decoded into structs");
        }

        const fields = type_info.@"struct".fields;

        const initial = try self.readInitialByte();
        if (initial.major_type != .map) return CborError.UnexpectedMajorType;
        if (initial.additional_info != 31) return CborError.UnexpectedMajorType; // Not indefinite

        var result: T = undefined;
        var fields_set = [_]bool{false} ** fields.len;
        var allocated_fields = [_]bool{false} ** fields.len;

        while (true) {
            // Check for break stop code
            const peek_byte = self.reader.readByte() catch return CborError.UnexpectedEndOfInput;
            if (peek_byte == BREAK_STOP_CODE) {
                break;
            }

            // Put the byte back and decode the key
            const major_type = @as(MajorType, @enumFromInt(peek_byte >> 5));
            const additional_info = @as(u5, @intCast(peek_byte & 0x1F));
            const restored_initial = InitialByte{ .major_type = major_type, .additional_info = additional_info };

            const key = try self.decodeValueFromInitial([]u8, restored_initial, depth + 1);
            defer self.allocator.free(key);

            var found = false;
            inline for (fields, 0..) |field, field_idx| {
                if (std.mem.eql(u8, key, field.name)) {
                    @field(result, field.name) = self.decodeWithDepth(field.type, depth + 1) catch |err| {
                        // Clean up any fields that were already allocated
                        inline for (fields, 0..) |cleanup_field, cleanup_idx| {
                            if (allocated_fields[cleanup_idx]) {
                                const field_type_info = @typeInfo(cleanup_field.type);
                                if (field_type_info == .pointer and field_type_info.pointer.size == .slice and field_type_info.pointer.child == u8) {
                                    self.allocator.free(@field(result, cleanup_field.name));
                                }
                            }
                        }
                        return err;
                    };
                    fields_set[field_idx] = true;
                    // Mark fields that allocate memory
                    const field_type_info = @typeInfo(field.type);
                    if (field_type_info == .pointer and field_type_info.pointer.size == .slice) {
                        allocated_fields[field_idx] = true;
                    }
                    found = true;
                    break;
                }
            }

            if (!found) {
                // Skip unknown field value
                try self.skipValue();
            }
        }

        // Check that all required fields were set
        inline for (fields, 0..) |field, field_idx| {
            if (!fields_set[field_idx]) {
                if (@typeInfo(field.type) == .optional) {
                    @field(result, field.name) = null;
                } else {
                    // Clean up any fields that were already allocated before returning error
                    inline for (fields, 0..) |cleanup_field, cleanup_idx| {
                        if (allocated_fields[cleanup_idx]) {
                            const field_type_info = @typeInfo(cleanup_field.type);
                            if (field_type_info == .pointer and field_type_info.pointer.size == .slice and field_type_info.pointer.child == u8) {
                                self.allocator.free(@field(result, cleanup_field.name));
                            }
                        }
                    }
                    return CborError.MissingRequiredField;
                }
            }
        }

        return result;
    }

    fn extractFieldFromMap(self: *Decoder, comptime T: type, field_name: []const u8) !?T {
        const initial = try self.readInitialByte();
        if (initial.major_type != .map) return CborError.UnexpectedMajorType;

        if (initial.additional_info == 31) {
            // Indefinite-length map
            return try self.extractFromIndefiniteMap(T, field_name);
        } else {
            // Definite-length map
            const length = try self.readLength(initial.additional_info);
            return try self.extractFromDefiniteMap(T, field_name, length);
        }
    }

    fn extractFromDefiniteMap(self: *Decoder, comptime T: type, field_name: []const u8, length: u64) !?T {
        var i: u64 = 0;
        while (i < length) : (i += 1) {
            // Decode the key
            const key = try self.decodeWithDepth([]u8, 1);
            defer self.allocator.free(key);

            if (std.mem.eql(u8, key, field_name)) {
                // Found the field we're looking for, decode and return its value
                return try self.decodeWithDepth(T, 1);
            } else {
                // Skip the value for this key
                try self.skipValue();
            }
        }
        return null; // Field not found
    }

    fn extractFromIndefiniteMap(self: *Decoder, comptime T: type, field_name: []const u8) !?T {
        while (true) {
            // Check for break stop code
            const peek_byte = self.reader.readByte() catch return CborError.UnexpectedEndOfInput;
            if (peek_byte == BREAK_STOP_CODE) {
                break;
            }

            // Put the byte back and decode the key
            const major_type = @as(MajorType, @enumFromInt(peek_byte >> 5));
            const additional_info = @as(u5, @intCast(peek_byte & 0x1F));
            const restored_initial = InitialByte{ .major_type = major_type, .additional_info = additional_info };

            const key = try self.decodeValueFromInitial([]u8, restored_initial, 1);
            defer self.allocator.free(key);

            if (std.mem.eql(u8, key, field_name)) {
                // Found the field we're looking for, decode and return its value
                return try self.decodeWithDepth(T, 1);
            } else {
                // Skip the value for this key
                try self.skipValue();
            }
        }
        return null; // Field not found
    }
};

pub const CBOR = struct {
    allocator: Allocator,
    buffer: ArrayList(u8),
    config: Config,

    pub fn init(allocator: Allocator) CBOR {
        return CBOR{
            .allocator = allocator,
            .buffer = ArrayList(u8).init(allocator),
            .config = Config{},
        };
    }

    pub fn initWithConfig(allocator: Allocator, config: Config) CBOR {
        return CBOR{
            .allocator = allocator,
            .buffer = ArrayList(u8).init(allocator),
            .config = config,
        };
    }

    pub fn deinit(self: *CBOR) void {
        self.buffer.deinit();
    }

    pub fn encode(self: *CBOR, value: anytype) ![]u8 {
        self.buffer.clearRetainingCapacity();

        var encoder = Encoder.initWithConfig(self.buffer.writer().any(), self.config);
        try encoder.encode(value);

        return self.buffer.toOwnedSlice();
    }

    pub fn decode(self: *CBOR, comptime T: type, data: []const u8) !T {
        var stream = std.io.fixedBufferStream(data);
        var decoder = Decoder.initWithConfig(stream.reader().any(), self.allocator, self.config);
        return decoder.decode(T);
    }

    pub fn encodeWithConfig(self: *CBOR, value: anytype, config: Config) ![]u8 {
        self.buffer.clearRetainingCapacity();

        var encoder = Encoder.initWithConfig(self.buffer.writer().any(), config);
        try encoder.encode(value);

        return self.buffer.toOwnedSlice();
    }

    pub fn decodeWithConfig(self: *CBOR, comptime T: type, data: []const u8, config: Config) !T {
        var stream = std.io.fixedBufferStream(data);
        var decoder = Decoder.initWithConfig(stream.reader().any(), self.allocator, config);
        return decoder.decode(T);
    }

    pub fn extractField(self: *CBOR, comptime T: type, data: []const u8, field_name: []const u8) !?T {
        var stream = std.io.fixedBufferStream(data);
        var decoder = Decoder.initWithConfig(stream.reader().any(), self.allocator, self.config);
        return decoder.extractFieldFromMap(T, field_name);
    }

    pub fn encodeIndefiniteArray(self: *CBOR, items: anytype) ![]u8 {
        self.buffer.clearRetainingCapacity();

        var encoder = Encoder.initWithConfig(self.buffer.writer().any(), self.config);
        try encoder.encodeIndefiniteArray(items);

        return self.buffer.toOwnedSlice();
    }

    pub fn decodeIndefiniteArray(self: *CBOR, comptime T: type, data: []const u8) ![]T {
        var stream = std.io.fixedBufferStream(data);
        var decoder = Decoder.initWithConfig(stream.reader().any(), self.allocator, self.config);
        return decoder.decodeIndefiniteArray(T);
    }

    pub fn encodeIndefiniteMap(self: *CBOR, value: anytype) ![]u8 {
        self.buffer.clearRetainingCapacity();

        var encoder = Encoder.initWithConfig(self.buffer.writer().any(), self.config);
        try encoder.encodeIndefiniteMap(value);

        return self.buffer.toOwnedSlice();
    }

    pub fn decodeIndefiniteMap(self: *CBOR, comptime T: type, data: []const u8) !T {
        var stream = std.io.fixedBufferStream(data);
        var decoder = Decoder.initWithConfig(stream.reader().any(), self.allocator, self.config);
        return decoder.decodeIndefiniteMap(T);
    }
};

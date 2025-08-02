const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Config = struct {
    max_nesting_depth: u32 = 64,
    max_allocation_size: usize = 16 * 1024 * 1024,
};

pub const CborError = error{
    OutOfMemory,
    IoError,
    EndOfStream,
    TypeMismatch,
    NestingDepthExceeded,
    AllocationTooLarge,
    UnsupportedMajorType,
    InvalidAdditionalInfo,
    InvalidEnumTag,
    InvalidUnionRepresentation,
    MissingRequiredField,
};

pub const Serde = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    buffer: std.ArrayList(u8),
    config: Config,

    pub fn init(allocator: Allocator, config: Config) Serde {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .buffer = std.ArrayList(u8).init(allocator),
            .config = config,
        };
    }

    pub fn deinit(self: *Serde) void {
        self.arena.deinit();
        self.buffer.deinit();
    }

    pub fn serialize(self: *Serde, value: anytype) CborError![]u8 {
        if (self.buffer.items.len > 0) self.buffer.clearRetainingCapacity(); // Clear previous data
        var encoder = Encoder{ .writer = self.buffer.writer() };
        try self.serializeValue(&encoder, value);
        return self.buffer.toOwnedSlice();
    }

    pub fn deserialize(
        self: *Serde,
        bytes: []const u8,
        comptime T: type,
    ) CborError!T {
        var decoder = Decoder.init(&self.arena, bytes, self.config);
        return self.deserializeValue(&decoder, T);
    }

    fn serializeValue(self: *const Serde, encoder: *Encoder, value: anytype) !void {
        const T = @TypeOf(value);
        const info = @typeInfo(T);

        switch (info) {
            .@"struct" => {
                const fields = std.meta.fields(T);
                try encoder.encodeMapHeader(fields.len);
                inline for (fields) |field| {
                    try encoder.encodeString(field.name);
                    try self.serializeValue(encoder, @field(value, field.name));
                }
            },
            .pointer => |ptr| switch (ptr.size) {
                .slice => {
                    if (ptr.child == u8) {
                        try encoder.encodeBytes(value);
                    } else {
                        const items = value;
                        try encoder.encodeArrayHeader(items.len);
                        for (items) |item| {
                            try self.serializeValue(encoder, item);
                        }
                    }
                },
                else => @compileError("Unsupported pointer type: " ++ @typeName(T)),
            },
            .optional => |_| {
                if (value) |val| {
                    try self.serializeValue(encoder, val);
                } else {
                    try encoder.encodeNull();
                }
            },
            .@"enum" => try encoder.encodeString(@tagName(value)),
            .@"union" => |union_info| {
                if (union_info.tag_type == null) @compileError("Only tagged unions are supported.");
                try encoder.encodeArrayHeader(2);
                try encoder.encodeString(@tagName(value));
                switch (value) {
                    inline else => |payload| try self.serializeValue(encoder, payload),
                }
            },
            .int => |int_info| {
                if (int_info.signedness == .signed and value < 0) {
                    try encoder.encodeUInt(1, @intCast(-(value + 1)));
                } else {
                    try encoder.encodeUInt(0, @intCast(value));
                }
            },
            .float => |float_info| switch (float_info.bits) {
                32 => try encoder.encodeFloat32(@floatCast(value)),
                64 => try encoder.encodeFloat64(@floatCast(value)),
                else => @compileError("Unsupported float size."),
            },
            .bool => try encoder.encodeBool(value),
            else => @compileError("Unsupported type for serialization: " ++ @typeName(T)),
        }
    }

    fn deserializeValue(self: *const Serde, decoder: *Decoder, comptime T: type) CborError!T {
        const info = @typeInfo(T);

        return switch (info) {
            .@"struct" => {
                var result: T = undefined;
                if ((try decoder.peekByte()) >> 5 != 5) return error.TypeMismatch;
                const map_len = try decoder.decodeMapHeader();

                var populated_fields: u64 = 0;
                const fields = std.meta.fields(T);
                if (fields.len > 64) @compileError("Structs with >64 fields not supported.");

                var i: u64 = 0;
                while (i < map_len) : (i += 1) {
                    const key = try decoder.decodeString();
                    var found_key = false;
                    inline for (fields, 0..) |field, field_idx| {
                        if (std.mem.eql(u8, key, field.name)) {
                            @field(result, field.name) = try self.deserializeValue(decoder, field.type);
                            populated_fields |= (@as(u64, 1) << @intCast(field_idx));
                            found_key = true;
                            break;
                        }
                    }
                    if (!found_key) try decoder.skipValue();
                }

                inline for (fields, 0..) |field, field_idx| {
                    if ((populated_fields & (@as(u64, 1) << @intCast(field_idx))) == 0) {
                        if (@hasField(@TypeOf(field), "default_value")) {
                            if (field.default_value) |default_val| {
                                @field(result, field.name) = @as(*const field.type, @ptrCast(@alignCast(default_val))).*;
                            } else if (@typeInfo(field.type) == .Optional) {
                                @field(result, field.name) = null;
                            } else {
                                return error.MissingRequiredField;
                            }
                        } else {
                            // Fallback for older Zig versions that use "default"
                            if (@hasField(@TypeOf(field), "default")) {
                                if (@field(field, "default")) |default_val| {
                                    @field(result, field.name) = default_val;
                                } else if (@typeInfo(field.type) == .Optional) {
                                    @field(result, field.name) = null;
                                } else {
                                    return error.MissingRequiredField;
                                }
                            } else if (@typeInfo(field.type) == .optional) {
                                @field(result, field.name) = null;
                            } else {
                                return error.MissingRequiredField;
                            }
                        }
                    }
                }
                return result;
            },
            .pointer => |ptr| switch (ptr.size) {
                .slice => {
                    if (ptr.child == u8) {
                        return decoder.decodeBytes();
                    } else {
                        if ((try decoder.peekByte()) >> 5 != 4) return error.TypeMismatch;
                        const array_len = try decoder.decodeArrayHeader();
                        var list = try decoder.arena.allocator().alloc(ptr.child, array_len);
                        for (0..array_len) |j| {
                            list[j] = try self.deserializeValue(decoder, ptr.child);
                        }
                        return list;
                    }
                },
                else => @compileError("Unsupported pointer type: " ++ @typeName(T)),
            },
            .optional => |opt| {
                if ((try decoder.peekByte()) == 0xf6) { // null
                    _ = try decoder.readByte();
                    return null;
                }
                return try self.deserializeValue(decoder, opt.child);
            },
            .@"enum" => |enum_info| {
                const name = try decoder.decodeString();
                inline for (enum_info.fields) |field| {
                    if (std.mem.eql(u8, name, field.name)) {
                        return @as(T, @enumFromInt(field.value));
                    }
                }
                return error.InvalidEnumTag;
            },
            .@"union" => |union_info| {
                if (union_info.tag_type == null) @compileError("Only tagged unions supported.");
                if (try decoder.decodeArrayHeader() != 2) return error.InvalidUnionRepresentation;
                const tag_name = try decoder.decodeString();
                inline for (union_info.fields) |field| {
                    if (std.mem.eql(u8, tag_name, field.name)) {
                        const payload = try self.deserializeValue(decoder, field.type);
                        return @unionInit(T, field.name, payload);
                    }
                }
                return error.InvalidEnumTag;
            },
            .int => |_| {
                const head = try decoder.readByte();
                const val = try decoder.decodeUIntPayload(head & 0x1F);
                if (head >> 5 == 1) { // Negative
                    return std.math.cast(T, -1 - @as(i128, @intCast(val))) orelse error.IoError;
                }
                return std.math.cast(T, val) orelse error.IoError;
            },
            .float => |float_info| switch (float_info.bits) {
                32 => return @as(T, @bitCast(try decoder.decodeFloat32Payload())),
                64 => return @as(T, @bitCast(try decoder.decodeFloat64Payload())),
                else => @compileError("Unsupported float size."),
            },
            .bool => return decoder.decodeBool(),
            else => @compileError("Unsupported type for deserialization: " ++ @typeName(T)),
        };
    }

    fn extractField(self: *Serde, bytes: []const u8, field_name: []const u8, comptime T: type) CborError!?T {
        var decoder = Decoder.init(&self.arena, bytes, self.config);

        if ((try decoder.peekByte()) >> 5 != 5) return null;
        const map_len = try decoder.decodeMapHeader();

        var i: u64 = 0;
        while (i < map_len) : (i += 1) {
            const key = try decoder.decodeString();
            if (std.mem.eql(u8, key, field_name)) {
                return try self.deserializeValue(&decoder, T);
            } else {
                try decoder.skipValue();
            }
        }
        return null; 
    }
};

pub const Encoder = struct {
    writer: std.ArrayList(u8).Writer,

    fn encodeUInt(self: *Encoder, major_type: u8, len: u64) !void {
        const mt = major_type << 5;
        if (len < 24) {
            try self.writer.writeByte(mt | @as(u5, @intCast(len)));
        } else if (len <= std.math.maxInt(u8)) {
            try self.writer.writeByte(mt | 24);
            try self.writer.writeInt(u8, @as(u8, @intCast(len)), .big);
        } else if (len <= std.math.maxInt(u16)) {
            try self.writer.writeByte(mt | 25);
            try self.writer.writeInt(u16, @as(u16, @intCast(len)), .big);
        } else if (len <= std.math.maxInt(u32)) {
            try self.writer.writeByte(mt | 26);
            try self.writer.writeInt(u32, @as(u32, @intCast(len)), .big);
        } else {
            try self.writer.writeByte(mt | 27);
            try self.writer.writeInt(u64, len, .big);
        }
    }

    pub fn encodeBytes(self: *Encoder, bytes: []const u8) !void {
        try self.encodeUInt(2, bytes.len);
        try self.writer.writeAll(bytes);
    }

    pub fn encodeString(self: *Encoder, string: []const u8) !void {
        try self.encodeUInt(3, string.len);
        try self.writer.writeAll(string);
    }

    pub fn encodeArrayHeader(self: *Encoder, len: usize) !void {
        try self.encodeUInt(4, @intCast(len));
    }

    pub fn encodeMapHeader(self: *Encoder, len: usize) !void {
        try self.encodeUInt(5, @intCast(len));
    }

    pub fn encodeBool(self: *Encoder, value: bool) !void {
        try self.writer.writeByte(if (value) 0xf5 else 0xf4);
    }

    pub fn encodeNull(self: *Encoder) !void {
        try self.writer.writeByte(0xf6);
    }

    pub fn encodeFloat32(self: *Encoder, value: f32) !void {
        try self.writer.writeByte(0xfa);
        try self.writer.writeInt(u32, @bitCast(value), .big);
    }

    pub fn encodeFloat64(self: *Encoder, value: f64) !void {
        try self.writer.writeByte(0xfb);
        try self.writer.writeInt(u64, @bitCast(value), .big);
    }
};

pub const Decoder = struct {
    stream: std.io.FixedBufferStream([]const u8),
    arena: *std.heap.ArenaAllocator,
    config: Config,
    depth: u32,

    pub fn init(arena: *std.heap.ArenaAllocator, bytes: []const u8, config: Config) Decoder {
        return .{
            .stream = std.io.fixedBufferStream(bytes),
            .arena = arena,
            .config = config,
            .depth = 0,
        };
    }

    fn readByte(self: *Decoder) !u8 {
        return self.stream.reader().readByte();
    }

    fn peekByte(self: *Decoder) !u8 {
        const original_pos = self.stream.pos;
        defer self.stream.pos = original_pos;
        return self.stream.reader().readByte();
    }

    fn decodeUIntPayload(self: *Decoder, add_info: u8) CborError!u64 {
        return switch (add_info) {
            0...23 => @intCast(add_info),
            24 => try self.stream.reader().readInt(u8, .big),
            25 => try self.stream.reader().readInt(u16, .big),
            26 => try self.stream.reader().readInt(u32, .big),
            27 => try self.stream.reader().readInt(u64, .big),
            else => error.InvalidAdditionalInfo,
        };
    }

    fn decodeArrayHeader(self: *Decoder) !u64 {
        const head = try self.readByte();
        if (head >> 5 != 4) return error.TypeMismatch;
        return self.decodeUIntPayload(head & 0x1F);
    }

    fn decodeMapHeader(self: *Decoder) !u64 {
        const head = try self.readByte();
        if (head >> 5 != 5) return error.TypeMismatch;
        return self.decodeUIntPayload(head & 0x1F);
    }

    fn decodeBytes(self: *Decoder) ![]u8 {
        const head = try self.readByte();
        const major_type = head >> 5;
        if (major_type != 2 and major_type != 3) return error.TypeMismatch;
        const len = try self.decodeUIntPayload(head & 0x1F);
        if (len > self.config.max_allocation_size) return error.AllocationTooLarge;
        const bytes = try self.arena.allocator().alloc(u8, @intCast(len));
        try self.stream.reader().readNoEof(bytes);
        return bytes;
    }

    fn decodeString(self: *Decoder) ![]u8 {
        const head = try self.readByte();
        if (head >> 5 != 3) return error.TypeMismatch;
        const len = try self.decodeUIntPayload(head & 0x1F);
        if (len > self.config.max_allocation_size) return error.AllocationTooLarge;
        const bytes = try self.arena.allocator().alloc(u8, @intCast(len));
        try self.stream.reader().readNoEof(bytes);
        return bytes;
    }

    fn decodeBool(self: *Decoder) !bool {
        return switch (try self.readByte()) {
            0xf4 => false,
            0xf5 => true,
            else => error.TypeMismatch,
        };
    }

    fn decodeFloat32Payload(self: *Decoder) !u32 {
        if (try self.readByte() != 0xfa) return error.TypeMismatch;
        return self.stream.reader().readInt(u32, .big);
    }

    fn decodeFloat64Payload(self: *Decoder) !u64 {
        if (try self.readByte() != 0xfb) return error.TypeMismatch;
        return self.stream.reader().readInt(u64, .big);
    }

    fn skipValue(self: *Decoder) !void {
        self.depth += 1;
        if (self.depth > self.config.max_nesting_depth) return error.NestingDepthExceeded;
        defer self.depth -= 1;
        const head = try self.readByte();
        const major_type = head >> 5;
        const add_info = head & 0x1F;
        switch (major_type) {
            0, 1 => _ = try self.decodeUIntPayload(add_info),
            2, 3 => {
                const len = try self.decodeUIntPayload(add_info);
                try self.stream.reader().skipBytes(@intCast(len), .{});
            },
            4 => {
                const len = try self.decodeUIntPayload(add_info);
                var i: u64 = 0;
                while (i < len) : (i += 1) try self.skipValue();
            },
            5 => {
                const len = try self.decodeUIntPayload(add_info);
                var i: u64 = 0;
                while (i < len) : (i += 1) {
                    try self.skipValue();
                    try self.skipValue();
                }
            },
            6 => try self.skipValue(),
            7 => switch (add_info) {
                24 => try self.stream.reader().skipBytes(1, .{}),
                25 => try self.stream.reader().skipBytes(2, .{}),
                26 => try self.stream.reader().skipBytes(4, .{}),
                27 => try self.stream.reader().skipBytes(8, .{}),
                else => {},
            },
            else => @panic("unreachable"),
        }
    }
};

test "deserialize request with missing optional field" {
    const allocator = std.testing.allocator;
    const Operation = enum { create };
    const OpsTarget = enum { document, index };
    const Ops = union(OpsTarget) { document: Operation, index: Operation };
    const MyRequest = struct {
        operation: Ops,
        space: ?[]const u8 = null,
    };
    var serde = Serde.init(allocator, .{});
    defer serde.deinit();
    const cbor_bytes = &.{ 0xa1, 0x69, 0x6f, 0x70, 0x65, 0x72, 0x61, 0x74, 0x69, 0x6f, 0x6e, 0x82, 0x68, 0x64, 0x6f, 0x63, 0x75, 0x6d, 0x65, 0x6e, 0x74, 0x66, 0x63, 0x72, 0x65, 0x61, 0x74, 0x65 };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const req = try serde.deserialize(cbor_bytes, MyRequest);

    try std.testing.expect(req.operation.document == .create);
    try std.testing.expect(req.space == null);
}

test "deserialize fails on missing required field" {
    const allocator = std.testing.allocator;
    const MyRequest = struct {
        id: u64,
        name: []const u8,
    };
    var serde = Serde.init(allocator, .{});
    defer serde.deinit();
    const cbor_bytes = &.{ 0xa1, 0x62, 0x69, 0x64, 0x18, 0x7b };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const result = serde.deserialize(cbor_bytes, MyRequest);
    try std.testing.expectError(error.MissingRequiredField, result);
}

test "serialize and deserialize struct with optional field" {
    const allocator = std.testing.allocator;
    const MyStruct = struct {
        id: u64,
        name: []const u8,
        description: ?[]const u8 = null,
    };
    var serde = Serde.init(allocator, .{});
    defer serde.deinit();

    const original = MyStruct{
        .id = 42,
        .name = "Test",
        .description = null,
    };

    const serialized = try serde.serialize(original);
    defer allocator.free(serialized);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const deserialized = try serde.deserialize(serialized, MyStruct);

    try std.testing.expect(deserialized.id == original.id);
    try std.testing.expect(std.mem.eql(u8, deserialized.name, original.name));
    try std.testing.expect(deserialized.description == null);
}

test "extract field from serialized data" {
    const allocator = std.testing.allocator;
    const MyStruct = struct {
        id: u64,
        name: []const u8,
        city: []const u8,
    };
    var serde = Serde.init(allocator, .{});
    defer serde.deinit();

    const original = MyStruct{
        .id = 42,
        .name = "Test",
        .city = "Pune",
    };

    const serialized = try serde.serialize(original);
    defer allocator.free(serialized);

    const extracted_id = try serde.extractField(serialized, "id", u64);
    try std.testing.expect(extracted_id == 42);

    const extracted_name = try serde.extractField(serialized, "name", []const u8);
    if (extracted_name) |name| {
        std.debug.print("Extracted name: {s}\n", .{name});
        try std.testing.expect(std.mem.eql(u8, name, "Test"));
    } else {
        std.debug.print("Extracted name not found\n", .{});
        try std.testing.expect(false);
    }

    const extracted_city = try serde.extractField(serialized, "city", []const u8);
    if (extracted_city) |city| {
        std.debug.print("Extracted city: {s}\n", .{city});
        try std.testing.expect(std.mem.eql(u8, city, "Pune"));
    } else {
        std.debug.print("Extracted name not found\n", .{});
        try std.testing.expect(false);
    }
}

test "serde person struct with array of address structs" {
    const allocator = std.testing.allocator;
    const Address = struct {
        street: []const u8,
        city: []const u8,
    };
    const Person = struct {
        name: []const u8,
        age: u32,
        addresses: []Address,
    };

    var serde = Serde.init(allocator, .{});
    defer serde.deinit();

    const person = Person{
        .name = "Alice",
        .age = 30,
        .addresses = try allocator.dupe(Address, &[_]Address{
            Address{ .street = "123 Main St", .city = "Wonderland" },
            Address{ .street = "456 Elm St", .city = "Dreamland" },
        }),
    };

    defer allocator.free(person.addresses);

    const serialized = try serde.serialize(person);
    defer allocator.free(serialized);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const deserialized_person = try serde.deserialize(serialized, Person);

    try std.testing.expect(std.mem.eql(u8, deserialized_person.name, person.name));
    try std.testing.expect(deserialized_person.age == person.age);
    try std.testing.expect(deserialized_person.addresses.len == person.addresses.len);

    for (0..deserialized_person.addresses.len) |i| {
        try std.testing.expect(std.mem.eql(u8, deserialized_person.addresses[i].street, person.addresses[i].street));
        try std.testing.expect(std.mem.eql(u8, deserialized_person.addresses[i].city, person.addresses[i].city));
    }
}

test "serde struct with all sorts of types" {
    const allocator = std.testing.allocator;
    const MyStruct = struct {
        id: u64,
        age: i64,
        score: f32,
        name: []const u8,
        active: bool,
        tags: [][]const u8,
    };
    var serde = Serde.init(allocator, .{});
    defer serde.deinit();

    var tags_array = [_][]const u8{ "tag1", "tag2", "tag3" };

    const original = MyStruct{
        .id = 42,
        .age = 30,
        .score = 85.5,
        .name = "Test",
        .active = true,
        .tags = &tags_array,
    };

    const serialized = try serde.serialize(original);
    defer allocator.free(serialized);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const deserialized = try serde.deserialize(serialized, MyStruct);

    try std.testing.expect(deserialized.id == original.id);
    try std.testing.expect(std.mem.eql(u8, deserialized.name, original.name));
    try std.testing.expect(deserialized.active == original.active);
    try std.testing.expect(deserialized.tags.len == original.tags.len);
    try std.testing.expect(deserialized.age == original.age);
    try std.testing.expect(deserialized.score == original.score);
    for (0..deserialized.tags.len) |i| {
        try std.testing.expect(std.mem.eql(u8, deserialized.tags[i], original.tags[i]));
    }
}

test "serde deeply nested up 5 levels" {
    const allocator = std.testing.allocator;
    const InnerMost = struct {
        level: u8 = 5,
        name: []const u8 = "InnerMost",
        value: u64,
    };
    const Inner = struct {
        level: u8 = 4,
        name: []const u8 = "Inner",
        inner_most: InnerMost,
    };
    const Middle = struct {
        level: u8 = 3,
        name: []const u8 = "Middle",
        inner: Inner,
    };
    const Outer = struct {
        level: u8 = 2,
        name: []const u8 = "Outer",
        middle: Middle,
    };
    const DeeplyNested = struct {
        level: u8 = 1,
        name: []const u8 = "DeeplyNested",
        outer: Outer,
    };

    var serde = Serde.init(allocator, .{});
    defer serde.deinit();

    const original = DeeplyNested{
        .outer = Outer{
            .middle = Middle{
                .inner = Inner{
                    .inner_most = InnerMost{ .value = 12345 },
                },
            },
        },
    };

    const serialized = try serde.serialize(original);
    defer allocator.free(serialized);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const deserialized = try serde.deserialize(serialized, DeeplyNested);

    try std.testing.expect(deserialized.outer.middle.inner.inner_most.value == original.outer.middle.inner.inner_most.value);
}

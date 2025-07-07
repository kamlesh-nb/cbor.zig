const std = @import("std");
const ArrayList = std.ArrayList;
const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;
const expectError = testing.expectError;

const cbor = @import("src/root.zig");
const CBOR = cbor.CBOR;
const Config = cbor.Config;
const CborError = cbor.CborError;
const Encoder = cbor.Encoder;
const Decoder = cbor.Decoder;

test "encode/decode integers - various sizes" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    // Test various unsigned integer sizes
    inline for ([_]type{ u8, u16, u32, u64 }) |T| {
        const values = [_]T{ 0, 1, 23, 24, 255, std.math.maxInt(T) };
        for (values) |value| {
            const data = try cbor_instance.encode(value);
            defer allocator.free(data);
            const decoded = try cbor_instance.decode(T, data);
            try expectEqual(value, decoded);
        }
    }

    // Test various signed integer sizes
    inline for ([_]type{ i8, i16, i32, i64 }) |T| {
        const values = [_]T{ std.math.minInt(T), -1, 0, 1, std.math.maxInt(T) };
        for (values) |value| {
            const data = try cbor_instance.encode(value);
            defer allocator.free(data);
            const decoded = try cbor_instance.decode(T, data);
            try expectEqual(value, decoded);
        }
    }
}

test "encode/decode floats - all types" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    // f16
    {
        const values = [_]f16{ 0.0, 1.0, -1.0, 3.14 };
        for (values) |value| {
            const data = try cbor_instance.encode(value);
            defer allocator.free(data);
            const decoded = try cbor_instance.decode(f16, data);
            try expectEqual(value, decoded);
        }
    }

    // f32
    {
        const values = [_]f32{ 0.0, 1.0, -1.0, 3.14159, std.math.inf(f32), -std.math.inf(f32) };
        for (values) |value| {
            const data = try cbor_instance.encode(value);
            defer allocator.free(data);
            const decoded = try cbor_instance.decode(f32, data);
            if (std.math.isInf(value)) {
                try testing.expect(std.math.isInf(decoded));
                try expectEqual(std.math.sign(value), std.math.sign(decoded));
            } else {
                try expectEqual(value, decoded);
            }
        }
    }

    // f64
    {
        const values = [_]f64{ 0.0, 1.0, -1.0, 3.141592653589793, std.math.inf(f64), -std.math.inf(f64) };
        for (values) |value| {
            const data = try cbor_instance.encode(value);
            defer allocator.free(data);
            const decoded = try cbor_instance.decode(f64, data);
            if (std.math.isInf(value)) {
                try testing.expect(std.math.isInf(decoded));
                try expectEqual(std.math.sign(value), std.math.sign(decoded));
            } else {
                try expectEqual(value, decoded);
            }
        }
    }

    // NaN test
    {
        const nan_f32 = std.math.nan(f32);
        const data = try cbor_instance.encode(nan_f32);
        defer allocator.free(data);
        const decoded = try cbor_instance.decode(f32, data);
        try testing.expect(std.math.isNan(decoded));
    }
}

test "encode/decode booleans" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    const values = [_]bool{ true, false };
    for (values) |value| {
        const data = try cbor_instance.encode(value);
        defer allocator.free(data);
        const decoded = try cbor_instance.decode(bool, data);
        try expectEqual(value, decoded);
    }
}

test "encode/decode strings - various lengths" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    const test_strings = [_][]const u8{
        "",
        "Hello",
        "Hello, CBOR!",
        "Unicode: 🦀🔥",
        "A" ** 23, // Edge case: exactly 23 bytes
        "B" ** 24, // Edge case: exactly 24 bytes
        "C" ** 255, // Edge case: exactly 255 bytes
    };

    for (test_strings) |original| {
        const data = try cbor_instance.encode(original);
        defer allocator.free(data);

        const decoded = try cbor_instance.decode([]u8, data);
        defer allocator.free(decoded);

        try expectEqualSlices(u8, original, decoded);
    }
}

test "encode/decode arrays - various types and sizes" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    // Empty array
    {
        const original = [_]u32{};
        const data = try cbor_instance.encode(original);
        defer allocator.free(data);

        const decoded = try cbor_instance.decode([]u32, data);
        defer allocator.free(decoded);

        try expectEqualSlices(u32, &original, decoded);
    }

    // Small array
    {
        const original = [_]u32{ 1, 2, 3, 4, 5 };
        const data = try cbor_instance.encode(original);
        defer allocator.free(data);

        const decoded = try cbor_instance.decode([]u32, data);
        defer allocator.free(decoded);

        try expectEqualSlices(u32, &original, decoded);
    }

    // Array of strings
    {
        const original = [_][]const u8{ "hello", "world", "test" };
        const data = try cbor_instance.encode(original);
        defer allocator.free(data);

        const decoded = try cbor_instance.decode([][]u8, data);
        defer {
            for (decoded) |str| allocator.free(str);
            allocator.free(decoded);
        }

        try expectEqual(original.len, decoded.len);
        for (original, decoded) |orig, dec| {
            try expectEqualSlices(u8, orig, dec);
        }
    }

    // Nested arrays
    {
        const original = [_][2]u32{ .{ 1, 2 }, .{ 3, 4 }, .{ 5, 6 } };
        const data = try cbor_instance.encode(original);
        defer allocator.free(data);

        const decoded = try cbor_instance.decode([][2]u32, data);
        defer allocator.free(decoded);

        try expectEqual(original.len, decoded.len);
        for (original, decoded) |orig, dec| {
            try expectEqualSlices(u32, &orig, &dec);
        }
    }
}

test "encode/decode structs - various configurations" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    // Simple struct
    {
        const Person = struct {
            name: []const u8,
            age: u32,
            active: bool,
        };

        const original = Person{
            .name = "Alice",
            .age = 30,
            .active = true,
        };

        const data = try cbor_instance.encode(original);
        defer allocator.free(data);

        const decoded = try cbor_instance.decode(Person, data);
        defer allocator.free(decoded.name);

        try expectEqualSlices(u8, original.name, decoded.name);
        try expectEqual(original.age, decoded.age);
        try expectEqual(original.active, decoded.active);
    }

    // Struct with optional fields
    {
        const PersonOpt = struct {
            name: []const u8,
            age: ?u32 = null,
            nickname: ?[]const u8 = null,
        };

        // With optional values present
        {
            const original = PersonOpt{
                .name = "Bob",
                .age = 25,
                .nickname = "Bobby",
            };

            const data = try cbor_instance.encode(original);
            defer allocator.free(data);

            const decoded = try cbor_instance.decode(PersonOpt, data);
            defer {
                allocator.free(decoded.name);
                if (decoded.nickname) |nick| allocator.free(nick);
            }

            try expectEqualSlices(u8, original.name, decoded.name);
            try expectEqual(original.age, decoded.age);
            try expectEqualSlices(u8, original.nickname.?, decoded.nickname.?);
        }

        // With optional values null
        {
            const original = PersonOpt{
                .name = "Charlie",
                .age = null,
                .nickname = null,
            };

            const data = try cbor_instance.encode(original);
            defer allocator.free(data);

            const decoded = try cbor_instance.decode(PersonOpt, data);
            defer allocator.free(decoded.name);

            try expectEqualSlices(u8, original.name, decoded.name);
            try expectEqual(original.age, decoded.age);
            try expectEqual(original.nickname, decoded.nickname);
        }
    }

    // Nested structs
    {
        const Address = struct {
            street: []const u8,
            city: []const u8,
        };

        const PersonWithAddress = struct {
            name: []const u8,
            address: Address,
        };

        const original = PersonWithAddress{
            .name = "Dave",
            .address = Address{
                .street = "123 Main St",
                .city = "Anytown",
            },
        };

        const data = try cbor_instance.encode(original);
        defer allocator.free(data);

        const decoded = try cbor_instance.decode(PersonWithAddress, data);
        defer {
            allocator.free(decoded.name);
            allocator.free(decoded.address.street);
            allocator.free(decoded.address.city);
        }

        try expectEqualSlices(u8, original.name, decoded.name);
        try expectEqualSlices(u8, original.address.street, decoded.address.street);
        try expectEqualSlices(u8, original.address.city, decoded.address.city);
    }
}

test "encode/decode optionals - comprehensive" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    // Optional integers
    {
        const test_values = [_]?i32{ null, 0, 42, -100 };
        for (test_values) |original| {
            const data = try cbor_instance.encode(original);
            defer allocator.free(data);

            const decoded = try cbor_instance.decode(?i32, data);
            try expectEqual(original, decoded);
        }
    }

    // Optional strings
    {
        const test_values = [_]?[]const u8{ null, "hello", "" };
        for (test_values) |original| {
            const data = try cbor_instance.encode(original);
            defer allocator.free(data);

            const decoded = try cbor_instance.decode(?[]u8, data);
            defer if (decoded) |s| allocator.free(s);

            if (original) |orig_str| {
                try expectEqualSlices(u8, orig_str, decoded.?);
            } else {
                try expectEqual(@as(?[]u8, null), decoded);
            }
        }
    }

    // Optional booleans
    {
        const test_values = [_]?bool{ null, true, false };
        for (test_values) |original| {
            const data = try cbor_instance.encode(original);
            defer allocator.free(data);

            const decoded = try cbor_instance.decode(?bool, data);
            try expectEqual(original, decoded);
        }
    }
}

test "encode/decode void" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    const data = try cbor_instance.encode({});
    defer allocator.free(data);

    const decoded = try cbor_instance.decode(void, data);
    try expectEqual({}, decoded);
}

test "error handling - type mismatches" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    // Try to decode integer as bool
    {
        const data = try cbor_instance.encode(@as(u32, 42));
        defer allocator.free(data);

        try expectError(CborError.UnexpectedMajorType, cbor_instance.decode(bool, data));
    }

    // Try to decode bool as integer
    {
        const data = try cbor_instance.encode(true);
        defer allocator.free(data);

        try expectError(CborError.UnexpectedMajorType, cbor_instance.decode(u32, data));
    }

    // Try to decode f32 as f64
    {
        const data = try cbor_instance.encode(@as(f32, 3.14));
        defer allocator.free(data);

        try expectError(CborError.FloatTypeMismatch, cbor_instance.decode(f64, data));
    }

    // Try to decode negative integer as unsigned
    {
        const data = try cbor_instance.encode(@as(i32, -42));
        defer allocator.free(data);

        try expectError(CborError.NegativeIntegerForUnsigned, cbor_instance.decode(u32, data));
    }
}

test "error handling - malformed data" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    // Truncated data
    {
        const data = [_]u8{0x18}; // uint8 indicator but no data
        try expectError(CborError.UnexpectedEndOfInput, cbor_instance.decode(u32, data[0..]));
    }

    // Invalid additional info
    {
        const data = [_]u8{0x1C}; // Invalid additional info (28)
        try expectError(CborError.InvalidAdditionalInfo, cbor_instance.decode(u32, data[0..]));
    }

    // Invalid boolean value
    {
        const data = [_]u8{0xF8}; // Float/simple with additional info 24 (invalid for bool)
        try expectError(CborError.InvalidBooleanValue, cbor_instance.decode(bool, data[0..]));
    }
}

test "error handling - integer overflow" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    // This would require carefully crafted CBOR data that represents
    // a number larger than what the target type can hold
    const large_number_data = [_]u8{ 0x1B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }; // Max u64
    try expectError(CborError.IntegerOverflow, cbor_instance.decode(u8, large_number_data[0..]));
}

test "error handling - missing required fields" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    const Person = struct {
        name: []const u8,
        age: u32, // required field
    };

    // Encode a map with only one field
    var buffer = ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var encoder = Encoder.init(buffer.writer().any());
    try encoder.encodeLength(.map, 1);
    try encoder.encodeText("name");
    try encoder.encodeText("Alice");

    const data = try buffer.toOwnedSlice();
    defer allocator.free(data);

    try expectError(CborError.MissingRequiredField, cbor_instance.decode(Person, data));
}

test "config limits - collection size" {
    const allocator = testing.allocator;

    const config = Config{
        .max_collection_size = 2,
        .max_string_length = 1000,
        .max_depth = 64,
    };

    var cbor_instance = CBOR.initWithConfig(allocator, config);
    defer cbor_instance.deinit();

    // Array too large
    {
        const large_array = [_]u32{ 1, 2, 3, 4, 5 }; // size 5 > limit 2
        try expectError(CborError.CollectionTooLarge, cbor_instance.encode(large_array));
    }
}

test "config limits - string length" {
    const allocator = testing.allocator;

    const config = Config{
        .max_collection_size = 1000,
        .max_string_length = 5,
        .max_depth = 64,
    };

    var cbor_instance = CBOR.initWithConfig(allocator, config);
    defer cbor_instance.deinit();

    const long_string: []const u8 = "this string is too long";
    try expectError(CborError.StringTooLong, cbor_instance.encode(long_string));
}

test "config limits - recursion depth" {
    const allocator = testing.allocator;

    const config = Config{
        .max_collection_size = 1000,
        .max_string_length = 1000,
        .max_depth = 2,
    };

    var cbor_instance = CBOR.initWithConfig(allocator, config);
    defer cbor_instance.deinit();

    // Create deeply nested structure
    const nested = [_][2][2]u32{
        [_][2]u32{
            [_]u32{ 1, 2 },
            [_]u32{ 3, 4 },
        },
    }; // depth > 2

    try expectError(CborError.CollectionTooLarge, cbor_instance.encode(nested));
}

test "memory safety - no leaks on decode errors" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    // This test ensures that when decoding fails partway through,
    // any allocated memory is properly cleaned up

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    // Create malformed data that will fail after allocating the name
    var buffer = ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var encoder = Encoder.init(buffer.writer().any());
    try encoder.encodeLength(.map, 2);
    try encoder.encodeText("name");
    try encoder.encodeText("Alice");
    try encoder.encodeText("age");
    // Missing the age value - this should cause an error

    const data = try buffer.toOwnedSlice();
    defer allocator.free(data);

    // This should fail but not leak the allocated "name" string
    const result = cbor_instance.decode(Person, data);
    try expectError(CborError.UnexpectedEndOfInput, result);
}

test "roundtrip compatibility" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    const ComplexStruct = struct {
        numbers: []i32,
        text: []const u8,
        optional_value: ?f64,
        nested: struct {
            flag: bool,
            items: [][]const u8,
        },
    };

    const original = ComplexStruct{
        .numbers = @constCast(&[_]i32{ 1, -2, 3, -4, 5 }),
        .text = "Hello, 世界! 🌍",
        .optional_value = 3.141592653589793,
        .nested = .{
            .flag = true,
            .items = @constCast(&[_][]const u8{ "item1", "item2", "item3" }),
        },
    };

    // First encode
    const data = try cbor_instance.encode(original);
    defer allocator.free(data);

    // Then decode
    const decoded = try cbor_instance.decode(ComplexStruct, data);
    defer {
        allocator.free(decoded.numbers);
        allocator.free(decoded.text);
        for (decoded.nested.items) |item| allocator.free(item);
        allocator.free(decoded.nested.items);
    }

    // Verify all fields
    try expectEqualSlices(i32, original.numbers, decoded.numbers);
    try expectEqualSlices(u8, original.text, decoded.text);
    try expectEqual(original.optional_value, decoded.optional_value);
    try expectEqual(original.nested.flag, decoded.nested.flag);
    try expectEqual(original.nested.items.len, decoded.nested.items.len);
    for (original.nested.items, decoded.nested.items) |orig, dec| {
        try expectEqualSlices(u8, orig, dec);
    }
}

test "edge cases - boundary values" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    // Test CBOR encoding boundary values (23, 24, 255, 256, etc.)
    const boundary_values = [_]u64{ 0, 1, 23, 24, 255, 256, 65535, 65536, 4294967295, 4294967296 };

    for (boundary_values) |value| {
        // Skip values that would overflow smaller types
        if (value <= std.math.maxInt(u32)) {
            const data = try cbor_instance.encode(@as(u32, @intCast(value)));
            defer allocator.free(data);
            const decoded = try cbor_instance.decode(u32, data);
            try expectEqual(@as(u32, @intCast(value)), decoded);
        }
    }
}

test "unknown fields in structs are skipped" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    const SimpleStruct = struct {
        name: []const u8,
        age: u32,
    };

    // Manually create CBOR data with extra fields
    var buffer = ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var encoder = Encoder.init(buffer.writer().any());
    try encoder.encodeLength(.map, 4); // 4 fields, but struct only has 2

    try encoder.encodeText("name");
    try encoder.encodeText("Alice");

    try encoder.encodeText("age");
    try encoder.encode(@as(u32, 30));

    try encoder.encodeText("unknown_field");
    try encoder.encodeText("should be skipped");

    try encoder.encodeText("another_unknown");
    try encoder.encode(@as(bool, true));

    const data = try buffer.toOwnedSlice();
    defer allocator.free(data);

    const decoded = try cbor_instance.decode(SimpleStruct, data);
    defer allocator.free(decoded.name);

    try expectEqualSlices(u8, "Alice", decoded.name);
    try expectEqual(@as(u32, 30), decoded.age);
}

test "encode/decode arrays of structs" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    const Person = struct {
        name: []const u8,
        age: u32,
        active: bool,
    };

    const people = [_]Person{
        Person{ .name = "Alice", .age = 30, .active = true },
        Person{ .name = "Bob", .age = 25, .active = false },
        Person{ .name = "Charlie", .age = 35, .active = true },
    };

    // Test encoding and decoding array of structs
    const data = try cbor_instance.encode(people);
    defer allocator.free(data);

    const decoded = try cbor_instance.decode([]Person, data);
    defer {
        for (decoded) |person| {
            allocator.free(person.name);
        }
        allocator.free(decoded);
    }

    try expectEqual(people.len, decoded.len);
    for (people, decoded) |orig, dec| {
        try expectEqualSlices(u8, orig.name, dec.name);
        try expectEqual(orig.age, dec.age);
        try expectEqual(orig.active, dec.active);
    }
}

test "encode/decode indefinite-length arrays" {
    const allocator = testing.allocator;

    // Test simple indefinite array
    {
        const numbers = [_]u32{ 1, 2, 3, 4, 5 };

        var buffer = ArrayList(u8).init(allocator);
        defer buffer.deinit();

        var encoder = Encoder.init(buffer.writer().any());
        try encoder.encodeIndefiniteArray(numbers);

        const data = try buffer.toOwnedSlice();
        defer allocator.free(data);

        var stream = std.io.fixedBufferStream(data);
        var decoder = Decoder.init(stream.reader().any(), allocator);
        const decoded = try decoder.decodeIndefiniteArray(u32);
        defer allocator.free(decoded);

        try expectEqualSlices(u32, &numbers, decoded);
    }

    // Test indefinite array of strings
    {
        const strings = [_][]const u8{ "hello", "world", "test" };

        var buffer = ArrayList(u8).init(allocator);
        defer buffer.deinit();

        var encoder = Encoder.init(buffer.writer().any());
        try encoder.encodeIndefiniteArray(strings);

        const data = try buffer.toOwnedSlice();
        defer allocator.free(data);

        var stream = std.io.fixedBufferStream(data);
        var decoder = Decoder.init(stream.reader().any(), allocator);
        const decoded = try decoder.decodeIndefiniteArray([]u8);
        defer {
            for (decoded) |str| allocator.free(str);
            allocator.free(decoded);
        }

        try expectEqual(strings.len, decoded.len);
        for (strings, decoded) |orig, dec| {
            try expectEqualSlices(u8, orig, dec);
        }
    }

    // Test indefinite array of structs
    {
        const Person = struct {
            name: []const u8,
            age: u32,
        };

        const people = [_]Person{
            Person{ .name = "Alice", .age = 30 },
            Person{ .name = "Bob", .age = 25 },
        };

        var buffer = ArrayList(u8).init(allocator);
        defer buffer.deinit();

        var encoder = Encoder.init(buffer.writer().any());
        try encoder.encodeIndefiniteArray(people);

        const data = try buffer.toOwnedSlice();
        defer allocator.free(data);

        var stream = std.io.fixedBufferStream(data);
        var decoder = Decoder.init(stream.reader().any(), allocator);
        const decoded = try decoder.decodeIndefiniteArray(Person);
        defer {
            for (decoded) |person| allocator.free(person.name);
            allocator.free(decoded);
        }

        try expectEqual(people.len, decoded.len);
        for (people, decoded) |orig, dec| {
            try expectEqualSlices(u8, orig.name, dec.name);
            try expectEqual(orig.age, dec.age);
        }
    }
}

test "encode/decode indefinite-length maps" {
    const allocator = testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
        active: bool,
    };

    const person = Person{
        .name = "Alice",
        .age = 30,
        .active = true,
    };

    // Encode as indefinite-length map
    var buffer = ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var encoder = Encoder.init(buffer.writer().any());
    try encoder.encodeIndefiniteMap(person);

    const data = try buffer.toOwnedSlice();
    defer allocator.free(data);

    // Decode from indefinite-length map
    var stream = std.io.fixedBufferStream(data);
    var decoder = Decoder.init(stream.reader().any(), allocator);
    const decoded = try decoder.decodeIndefiniteMap(Person);
    defer allocator.free(decoded.name);

    try expectEqualSlices(u8, person.name, decoded.name);
    try expectEqual(person.age, decoded.age);
    try expectEqual(person.active, decoded.active);
}

test "indefinite-length arrays with mixed regular arrays" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    // Test that regular arrays still work after adding indefinite support
    const numbers = [_]u32{ 10, 20, 30 };
    const data = try cbor_instance.encode(numbers);
    defer allocator.free(data);

    const decoded = try cbor_instance.decode([]u32, data);
    defer allocator.free(decoded);

    try expectEqualSlices(u32, &numbers, decoded);
}

test "indefinite-length error handling" {
    const allocator = testing.allocator;

    // Test truncated indefinite array (missing break)
    {
        const malformed_data = [_]u8{
            0x9F, // Start indefinite array
            0x01, // Item: 1
            0x02, // Item: 2
            // Missing 0xFF break code
        };

        var stream = std.io.fixedBufferStream(malformed_data[0..]);
        var decoder = Decoder.init(stream.reader().any(), allocator);
        const result = decoder.decodeIndefiniteArray(u32);
        try expectError(CborError.UnexpectedEndOfInput, result);
    }

    // Test truncated indefinite map (missing break)
    {
        const TestStruct = struct { value: u32 };

        const malformed_data = [_]u8{
            0xBF, // Start indefinite map
            0x65, 0x76, 0x61, 0x6C, 0x75, 0x65, // Key: "value"
            0x18, 0x2A, // Value: 42
            // Missing 0xFF break code
        };

        var stream = std.io.fixedBufferStream(malformed_data[0..]);
        var decoder = Decoder.init(stream.reader().any(), allocator);
        const result = decoder.decodeIndefiniteMap(TestStruct);
        try expectError(CborError.UnexpectedEndOfInput, result);
    }
}

test "field extraction from definite-length maps" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    const TestStruct = struct {
        name: []u8,
        age: u32,
        active: bool,
    };

    const original = TestStruct{
        .name = @constCast("Alice"),
        .age = 30,
        .active = true,
    };

    // Encode the struct as a map
    const data = try cbor_instance.encode(original);
    defer allocator.free(data);

    // Extract individual fields
    {
        const extracted_name = try cbor_instance.extractField([]u8, data, "name");
        try testing.expect(extracted_name != null);
        defer allocator.free(extracted_name.?);
        try expectEqualSlices(u8, "Alice", extracted_name.?);
    }

    {
        const extracted_age = try cbor_instance.extractField(u32, data, "age");
        try testing.expect(extracted_age != null);
        try expectEqual(@as(u32, 30), extracted_age.?);
    }

    {
        const extracted_active = try cbor_instance.extractField(bool, data, "active");
        try testing.expect(extracted_active != null);
        try expectEqual(true, extracted_active.?);
    }

    // Try to extract non-existent field
    {
        const extracted_missing = try cbor_instance.extractField(u32, data, "missing_field");
        try testing.expect(extracted_missing == null);
    }
}

test "field extraction from indefinite-length maps" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    // Define a test struct to encode as an indefinite map
    const TestData = struct {
        name: []u8,
        score: f32,
        verified: bool,
    };

    const original = TestData{
        .name = @constCast("Bob"),
        .score = 95.5,
        .verified = false,
    };

    // Encode as indefinite-length map
    var buffer = ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var encoder = Encoder.init(buffer.writer().any());
    try encoder.encodeIndefiniteMap(original);

    const data = try buffer.toOwnedSlice();
    defer allocator.free(data);

    // Extract individual fields
    {
        const extracted_name = try cbor_instance.extractField([]u8, data, "name");
        try testing.expect(extracted_name != null);
        defer allocator.free(extracted_name.?);
        try expectEqualSlices(u8, "Bob", extracted_name.?);
    }

    {
        const extracted_score = try cbor_instance.extractField(f32, data, "score");
        try testing.expect(extracted_score != null);
        try expectEqual(@as(f32, 95.5), extracted_score.?);
    }

    {
        const extracted_verified = try cbor_instance.extractField(bool, data, "verified");
        try testing.expect(extracted_verified != null);
        try expectEqual(false, extracted_verified.?);
    }

    // Try to extract non-existent field
    {
        const extracted_missing = try cbor_instance.extractField(u32, data, "missing_field");
        try testing.expect(extracted_missing == null);
    }
}

test "field extraction with complex nested data" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    const NestedStruct = struct {
        id: u64,
        metadata: []u8,
        config: struct {
            enabled: bool,
            timeout: u32,
        },
        tags: [][]u8,
    };

    const original = NestedStruct{
        .id = 12345,
        .metadata = @constCast("important_data"),
        .config = .{
            .enabled = true,
            .timeout = 5000,
        },
        .tags = @constCast(&[_][]u8{ @constCast("urgent"), @constCast("production") }),
    };

    // Encode the complex struct
    const data = try cbor_instance.encode(original);
    defer allocator.free(data);

    // Extract just the ID field
    {
        const extracted_id = try cbor_instance.extractField(u64, data, "id");
        try testing.expect(extracted_id != null);
        try expectEqual(@as(u64, 12345), extracted_id.?);
    }

    // Extract just the metadata field
    {
        const extracted_metadata = try cbor_instance.extractField([]u8, data, "metadata");
        try testing.expect(extracted_metadata != null);
        defer allocator.free(extracted_metadata.?);
        try expectEqualSlices(u8, "important_data", extracted_metadata.?);
    }

    // Try to extract non-existent field
    {
        const extracted_missing = try cbor_instance.extractField(u32, data, "non_existent");
        try testing.expect(extracted_missing == null);
    }
}

test "field extraction error handling" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    // Test with non-map CBOR data (just an integer)
    {
        const data = try cbor_instance.encode(@as(u32, 42));
        defer allocator.free(data);

        const result = cbor_instance.extractField(u32, data, "any_field");
        try expectError(CborError.UnexpectedMajorType, result);
    }

    // Test with truncated data
    {
        const truncated_data = [_]u8{0xA1}; // Map with 1 item, but no content

        const result = cbor_instance.extractField(u32, truncated_data[0..], "field");
        try expectError(CborError.UnexpectedEndOfInput, result);
    }
}

test "ArrayList encoding and decoding" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    // Test ArrayList of integers
    {
        var numbers = ArrayList(u32).init(allocator);
        defer numbers.deinit();

        try numbers.append(10);
        try numbers.append(20);
        try numbers.append(30);
        try numbers.append(40);

        const data = try cbor_instance.encode(numbers);
        defer allocator.free(data);

        var decoded = try cbor_instance.decode(ArrayList(u32), data);
        defer decoded.deinit();

        try expectEqual(@as(usize, 4), decoded.items.len);
        try expectEqual(@as(u32, 10), decoded.items[0]);
        try expectEqual(@as(u32, 20), decoded.items[1]);
        try expectEqual(@as(u32, 30), decoded.items[2]);
        try expectEqual(@as(u32, 40), decoded.items[3]);
    }

    // Test empty ArrayList
    {
        var empty = ArrayList(i32).init(allocator);
        defer empty.deinit();

        const data = try cbor_instance.encode(empty);
        defer allocator.free(data);

        var decoded = try cbor_instance.decode(ArrayList(i32), data);
        defer decoded.deinit();

        try expectEqual(@as(usize, 0), decoded.items.len);
    }
}

test "struct with ArrayList fields" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    const Person = struct {
        name: []u8,
        age: u32,
        scores: ArrayList(f32),
    };

    // Create a Person with ArrayList
    var original_scores = ArrayList(f32).init(allocator);
    defer original_scores.deinit();
    try original_scores.append(95.5);
    try original_scores.append(88.2);
    try original_scores.append(92.7);

    const original = Person{
        .name = @constCast("Alice"),
        .age = 25,
        .scores = original_scores,
    };

    const data = try cbor_instance.encode(original);
    defer allocator.free(data);

    var decoded = try cbor_instance.decode(Person, data);
    defer {
        allocator.free(decoded.name);
        decoded.scores.deinit();
    }

    try expectEqualSlices(u8, "Alice", decoded.name);
    try expectEqual(@as(u32, 25), decoded.age);

    try expectEqual(@as(usize, 3), decoded.scores.items.len);
    try expectEqual(@as(f32, 95.5), decoded.scores.items[0]);
    try expectEqual(@as(f32, 88.2), decoded.scores.items[1]);
    try expectEqual(@as(f32, 92.7), decoded.scores.items[2]);
}

test "ArrayList of structs" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    const Point = struct {
        x: f32,
        y: f32,
    };

    var points = ArrayList(Point).init(allocator);
    defer points.deinit();

    try points.append(Point{ .x = 1.0, .y = 2.0 });
    try points.append(Point{ .x = 3.5, .y = 4.2 });
    try points.append(Point{ .x = -1.5, .y = 0.8 });

    const data = try cbor_instance.encode(points);
    defer allocator.free(data);

    var decoded = try cbor_instance.decode(ArrayList(Point), data);
    defer decoded.deinit();

    try expectEqual(@as(usize, 3), decoded.items.len);
    try expectEqual(@as(f32, 1.0), decoded.items[0].x);
    try expectEqual(@as(f32, 2.0), decoded.items[0].y);
    try expectEqual(@as(f32, 3.5), decoded.items[1].x);
    try expectEqual(@as(f32, 4.2), decoded.items[1].y);
    try expectEqual(@as(f32, -1.5), decoded.items[2].x);
    try expectEqual(@as(f32, 0.8), decoded.items[2].y);
}

test "field extraction from struct with ArrayList" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    const UserData = struct {
        id: u64,
        name: []u8,
        scores: ArrayList(u32),
    };

    var original_scores = ArrayList(u32).init(allocator);
    defer original_scores.deinit();
    try original_scores.append(100);
    try original_scores.append(95);
    try original_scores.append(88);

    const original = UserData{
        .id = 12345,
        .name = @constCast("TestUser"),
        .scores = original_scores,
    };

    const data = try cbor_instance.encode(original);
    defer allocator.free(data);

    // Extract just the ID field
    {
        const extracted_id = try cbor_instance.extractField(u64, data, "id");
        try testing.expect(extracted_id != null);
        try expectEqual(@as(u64, 12345), extracted_id.?);
    }

    // Extract just the name field
    {
        const extracted_name = try cbor_instance.extractField([]u8, data, "name");
        try testing.expect(extracted_name != null);
        defer allocator.free(extracted_name.?);
        try expectEqualSlices(u8, "TestUser", extracted_name.?);
    }

    // Extract the ArrayList field
    {
        var extracted_scores = try cbor_instance.extractField(ArrayList(u32), data, "scores");
        try testing.expect(extracted_scores != null);
        defer extracted_scores.?.deinit();

        try expectEqual(@as(usize, 3), extracted_scores.?.items.len);
        try expectEqual(@as(u32, 100), extracted_scores.?.items[0]);
        try expectEqual(@as(u32, 95), extracted_scores.?.items[1]);
        try expectEqual(@as(u32, 88), extracted_scores.?.items[2]);
    }
}

test "ArrayList of structs - comprehensive" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    // Define Address struct
    const Address = struct {
        street: []u8,
        city: []u8,
        zipcode: []u8,
        country: []u8,
    };

    // Define Person struct with ArrayList of Address
    const Person = struct {
        id: u64,
        name: []u8,
        email: []u8,
        addresses: ArrayList(Address),
    };

    // Create test data
    var addresses = ArrayList(Address).init(allocator);
    defer addresses.deinit();

    try addresses.append(Address{
        .street = @constCast("123 Main St"),
        .city = @constCast("New York"),
        .zipcode = @constCast("10001"),
        .country = @constCast("USA"),
    });

    try addresses.append(Address{
        .street = @constCast("456 Oak Ave"),
        .city = @constCast("Los Angeles"),
        .zipcode = @constCast("90210"),
        .country = @constCast("USA"),
    });

    try addresses.append(Address{
        .street = @constCast("789 Pine Rd"),
        .city = @constCast("Chicago"),
        .zipcode = @constCast("60601"),
        .country = @constCast("USA"),
    });

    const original = Person{
        .id = 42,
        .name = @constCast("John Doe"),
        .email = @constCast("john@example.com"),
        .addresses = addresses,
    };

    // Encode the Person with ArrayList of Address structs
    const data = try cbor_instance.encode(original);
    defer allocator.free(data);

    std.debug.print("Encoded Person with {} addresses: {} bytes\n", .{ original.addresses.items.len, data.len });

    // Decode back
    var decoded = try cbor_instance.decode(Person, data);
    defer {
        allocator.free(decoded.name);
        allocator.free(decoded.email);
        // Clean up ArrayList of structs
        for (decoded.addresses.items) |address| {
            allocator.free(address.street);
            allocator.free(address.city);
            allocator.free(address.zipcode);
            allocator.free(address.country);
        }
        decoded.addresses.deinit();
    }

    // Verify the data
    try expectEqual(@as(u64, 42), decoded.id);
    try expectEqualSlices(u8, "John Doe", decoded.name);
    try expectEqualSlices(u8, "john@example.com", decoded.email);
    try expectEqual(@as(usize, 3), decoded.addresses.items.len);

    // Verify first address
    const addr1 = decoded.addresses.items[0];
    try expectEqualSlices(u8, "123 Main St", addr1.street);
    try expectEqualSlices(u8, "New York", addr1.city);
    try expectEqualSlices(u8, "10001", addr1.zipcode);
    try expectEqualSlices(u8, "USA", addr1.country);

    // Verify second address
    const addr2 = decoded.addresses.items[1];
    try expectEqualSlices(u8, "456 Oak Ave", addr2.street);
    try expectEqualSlices(u8, "Los Angeles", addr2.city);
    try expectEqualSlices(u8, "90210", addr2.zipcode);
    try expectEqualSlices(u8, "USA", addr2.country);

    // Verify third address
    const addr3 = decoded.addresses.items[2];
    try expectEqualSlices(u8, "789 Pine Rd", addr3.street);
    try expectEqualSlices(u8, "Chicago", addr3.city);
    try expectEqualSlices(u8, "60601", addr3.zipcode);
    try expectEqualSlices(u8, "USA", addr3.country);
}

test "field extraction from ArrayList of structs" {
    const allocator = testing.allocator;

    var cbor_instance = CBOR.init(allocator);
    defer cbor_instance.deinit();

    const Contact = struct {
        type: []u8, // "work", "home", etc.
        value: []u8, // phone number, email, etc.
    };

    const User = struct {
        id: u64,
        username: []u8,
        contacts: ArrayList(Contact),
    };

    // Create test data
    var contacts = ArrayList(Contact).init(allocator);
    defer contacts.deinit();

    try contacts.append(Contact{
        .type = @constCast("email"),
        .value = @constCast("user@example.com"),
    });

    try contacts.append(Contact{
        .type = @constCast("phone"),
        .value = @constCast("+1-555-0123"),
    });

    try contacts.append(Contact{
        .type = @constCast("work_email"),
        .value = @constCast("user@company.com"),
    });

    const user = User{
        .id = 789,
        .username = @constCast("alice_wonder"),
        .contacts = contacts,
    };

    const data = try cbor_instance.encode(user);
    defer allocator.free(data);

    // Extract just the user ID
    {
        const extracted_id = try cbor_instance.extractField(u64, data, "id");
        try testing.expect(extracted_id != null);
        try expectEqual(@as(u64, 789), extracted_id.?);
    }

    // Extract just the username
    {
        const extracted_username = try cbor_instance.extractField([]u8, data, "username");
        try testing.expect(extracted_username != null);
        defer allocator.free(extracted_username.?);
        try expectEqualSlices(u8, "alice_wonder", extracted_username.?);
    }

    // Extract the entire ArrayList of Contact structs
    {
        var extracted_contacts = try cbor_instance.extractField(ArrayList(Contact), data, "contacts");
        try testing.expect(extracted_contacts != null);
        defer {
            for (extracted_contacts.?.items) |contact| {
                allocator.free(contact.type);
                allocator.free(contact.value);
            }
            extracted_contacts.?.deinit();
        }

        try expectEqual(@as(usize, 3), extracted_contacts.?.items.len);

        // Verify extracted contacts
        const contact1 = extracted_contacts.?.items[0];
        try expectEqualSlices(u8, "email", contact1.type);
        try expectEqualSlices(u8, "user@example.com", contact1.value);

        const contact2 = extracted_contacts.?.items[1];
        try expectEqualSlices(u8, "phone", contact2.type);
        try expectEqualSlices(u8, "+1-555-0123", contact2.value);

        const contact3 = extracted_contacts.?.items[2];
        try expectEqualSlices(u8, "work_email", contact3.type);
        try expectEqualSlices(u8, "user@company.com", contact3.value);
    }
}

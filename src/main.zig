const std = @import("std");
const zbor = @import("cbor.zig");
const ArrayList = std.ArrayList;

// Print CBOR bytes in hex format with nice formatting
fn printCborBytes(data: []const u8) void {
    std.debug.print("   CBOR bytes ({} bytes): ", .{data.len});
    for (data, 0..) |byte, i| {
        if (i > 0 and i % 16 == 0) {
            std.debug.print("\n                        ", .{});
        }
        std.debug.print("{X:02} ", .{byte});
    }
    std.debug.print("\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    _ = gpa.allocator();

    // Initialize CBOR configuration
    var custom_config = zbor.Config{};
    custom_config.max_collection_size = 1_000_000;
    custom_config.max_string_length = 1024 * 1024; // 1MB

    std.debug.print("🔥 COMPREHENSIVE CBOR LIBRARY DEMO 🔥\n", .{});
    std.debug.print("==========================================\n\n", .{});

    // 1. Basic Types Demo
    std.debug.print("1️⃣  BASIC TYPES ENCODING/DECODING\n", .{});
    std.debug.print("----------------------------------\n", .{});

    // Integers
    {
        const u8_val: u8 = 42;
        const i32_val: i32 = -1337;
        const u64_val: u64 = 1_000_000;

        inline for ([_]type{ u8, i32, u64 }, 0..) |T, i| {
            const value = switch (T) {
                u8 => u8_val,
                i32 => i32_val,
                u64 => u64_val,
                else => unreachable,
            };

            var buffer: [128]u8 = undefined;
            var encoder = zbor.Encoder.init(&buffer, custom_config);
            const len = try encoder.encode(value);
            const data = buffer[0..len];

            std.debug.print("   Integer {}: {} (type: {})\n", .{ i + 1, value, T });
            printCborBytes(data);

            var output: T = undefined;
            var decoder = zbor.Decoder.init(data, custom_config);
            try decoder.decode(T, &output);
            std.debug.print("   Decoded: {} ✓\n\n", .{output});
        }
    }

    // Floats
    {
        const f32_val: f32 = 3.14159;
        const f64_val: f64 = -123.456789;

        inline for ([_]type{ f32, f64 }, 0..) |T, i| {
            const value = switch (T) {
                f32 => f32_val,
                f64 => f64_val,
                else => unreachable,
            };

            var buffer: [128]u8 = undefined;
            var encoder = zbor.Encoder.init(&buffer, custom_config);
            const len = try encoder.encode(value);
            const data = buffer[0..len];

            std.debug.print("   Float {}: {d} (type: {})\n", .{ i + 1, value, T });
            printCborBytes(data);

            var output: T = undefined;
            var decoder = zbor.Decoder.init(data, custom_config);
            try decoder.decode(T, &output);
            std.debug.print("   Decoded: {d} ✓\n\n", .{output});
        }
    }

    // Booleans
    {
        const bool_values = [_]bool{ true, false };
        for (bool_values, 0..) |value, i| {
            var buffer: [128]u8 = undefined;
            var encoder = zbor.Encoder.init(&buffer, custom_config);
            const len = try encoder.encode(value);
            const data = buffer[0..len];

            std.debug.print("   Boolean {}: {}\n", .{ i + 1, value });
            printCborBytes(data);

            var output: bool = undefined;
            var decoder = zbor.Decoder.init(data, custom_config);
            try decoder.decode(bool, &output);
            std.debug.print("   Decoded: {} ✓\n\n", .{output});
        }
    }

    // 2. Strings Demo
    std.debug.print("2️⃣  STRINGS ENCODING/DECODING\n", .{});
    std.debug.print("-----------------------------\n", .{});

    {
        const strings = [_][]const u8{ "Hello, CBOR!", "Unicode: 🦀🔥✨", "" };
        for (strings, 0..) |str, i| {
            var buffer: [1024]u8 = undefined;
            var encoder = zbor.Encoder.init(&buffer, custom_config);
            const len = try encoder.encode(str);
            const data = buffer[0..len];

            std.debug.print("   String {}: \"{s}\"\n", .{ i + 1, str });
            printCborBytes(data);

            var output: []const u8 = undefined;
            var decoder = zbor.Decoder.init(data, custom_config);
            try decoder.decode([]const u8, &output);
            std.debug.print("   Decoded: \"{s}\" ✓\n\n", .{output});
        }
    }

    // 3. Arrays Demo
    std.debug.print("3️⃣  ARRAYS ENCODING/DECODING\n", .{});
    std.debug.print("----------------------------\n", .{});

    {
        const numbers = [_]u32{ 10, 20, 30, 40, 50 };
        var buffer: [1024]u8 = undefined;
        var encoder = zbor.Encoder.init(&buffer, custom_config);
        const len = try encoder.encode(numbers);
        const data = buffer[0..len];

        std.debug.print("   Array: [", .{});
        for (numbers, 0..) |num, i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("{}", .{num});
        }
        std.debug.print("]\n", .{});
        printCborBytes(data);

        var output: [5]u32 = undefined;
        var decoder = zbor.Decoder.init(data, custom_config);
        try decoder.decode([5]u32, &output);
        std.debug.print("   Decoded: [", .{});
        for (output, 0..) |num, i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("{}", .{num});
        }
        std.debug.print("] ✓\n\n", .{});
    }

    // 4. Structs Demo
    std.debug.print("4️⃣  STRUCTS ENCODING/DECODING\n", .{});
    std.debug.print("-----------------------------\n", .{});

    {
        const Point = struct {
            x: f32,
            y: f32,
            label: []const u8,
        };

        const point = Point{
            .x = 3.14,
            .y = -2.71,
            .label = "Origin",
        };

        var buffer: [1024]u8 = undefined;
        var encoder = zbor.Encoder.init(&buffer, custom_config);
        const len = try encoder.encode(point);
        const data = buffer[0..len];

        std.debug.print("   Struct: Point{{ x: {d}, y: {d}, label: \"{s}\" }}\n", .{ point.x, point.y, point.label });
        printCborBytes(data);

        var output: Point = undefined;
        var decoder = zbor.Decoder.init(data, custom_config);
        try decoder.decode(Point, &output);
        std.debug.print("   Decoded: Point{{ x: {d}, y: {d}, label: \"{s}\" }} ✓\n\n", .{ output.x, output.y, output.label });
    }

    // 5. SimpleArray Demo
    std.debug.print("5️⃣  SIMPLE ARRAY DEMO\n", .{});
    std.debug.print("--------------------\n", .{});

    {
        const scores = [_]u32{ 95, 87, 92, 88 };

        var buffer: [1024]u8 = undefined;
        var encoder = zbor.Encoder.init(&buffer, custom_config);
        const len = try encoder.encode(scores);
        const data = buffer[0..len];

        std.debug.print("   Array: [", .{});
        for (scores, 0..) |score, i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("{}", .{score});
        }
        std.debug.print("]\n", .{});
        printCborBytes(data);

        var output: [4]u32 = undefined;
        var decoder = zbor.Decoder.init(data, custom_config);
        try decoder.decode([4]u32, &output);
        std.debug.print("   Decoded: [", .{});
        for (output, 0..) |score, i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("{}", .{score});
        }
        std.debug.print("] ✓\n\n", .{});
    }

    std.debug.print("\n✅ CBOR DEMO COMPLETED SUCCESSFULLY\n", .{});
}

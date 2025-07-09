# CBOR.zig

A CBOR (Concise Binary Object Representation) implementation for Zig, compliant with RFC 8949.

## Features

- Zero-allocation encoding and decoding with fixed buffers.
- Supports integers, strings, arrays, maps, floats, and structs.
- Provides error handling and diagnostic messages.
- Suitable for embedded systems and other performance-sensitive applications.
- Includes SIMD-accelerated operations for UTF-8 validation and memory copying.

## Installation

Add the package to your `build.zig.zon`:

```zig
.dependencies = .{
    .cbor = .{
        .url = "https://github.com/yourusername/cbor.zig/archive/refs/tags/v1.0.0.tar.gz",
        // Add the appropriate hash for your release
    },
},
```

Then, add the module to your `build.zig`:

```zig
const cbor_dep = b.dependency("cbor", .{
    .target = target,
    .optimize = optimize,
});
exe.addModule("cbor", cbor_dep.module("cbor"));
```

## Basic Usage

```zig
const std = @import("std");
const cbor = @import("cbor");

pub fn main() !void {
    // Encoding example
    var buffer: [128]u8 = undefined;
    var encoder = cbor.Encoder.init(&buffer, .{});

    const value = 42;
    const len = try encoder.encode(value);
    const encoded_data = buffer[0..len];

    std.debug.print("Encoded: {any}\n", .{encoded_data});

    // Decoding example
    var decoder = cbor.Decoder.init(encoded_data, .{});

    var decoded_value: u8 = undefined;
    try decoder.decode(u8, &decoded_value);

    std.debug.print("Decoded: {}\n", .{decoded_value});
}
```

## Performance

Here is a performance comparison of `cbor.zig` against popular Go and Rust CBOR libraries. Benchmarks were run on an Apple M1 Pro. Lower is better.

| Benchmark                    | Zig (ns/op) | Go (ns/op) | Rust (ns/op) |
| ---------------------------- | ----------- | ---------- | ------------ |
| **Encode Integer** (65536)   | 6           | 60.26      | 29           |
| **Decode Integer** (65536)   | 6           | 45.68      | 6            |
| **Encode String** (69 chars) | 13          | 70.81      | 100          |
| **Decode String** (69 chars) | 2           | 72.76      | 43           |
| **Encode Array** (100 ints)  | 401         | 1301       | 708          |
| **Decode Array** (100 ints)  | 508         | 1686       | 340          |
| **Encode Struct** (simple)   | 69          | 155.4      | 230          |
| **Decode Struct** (simple)   | 53          | 193.0      | 86           |

_Note: These are simplified results. For detailed benchmark output, see the `bench` directory._

To run the benchmarks, navigate to the `bench/{zig,go,rust}` directories and follow the instructions in their respective README files (or build files).

## API

### `cbor.Encoder`

- `init(buffer: []u8, config: Config) -> Encoder`
- `encode(value: anytype) -> !usize`
- `encodeValue(value: anytype) -> !void`
- `encodeIndefiniteArray() -> !void`
- `encodeIndefiniteMap() -> !void`
- `encodeBreak() -> !void`

### `cbor.Decoder`

- `init(data: []const u8, config: Config) -> Decoder`
- `decode(comptime T: type, output: *T) -> !void`
- `decodeValue(comptime T: type) -> !T`
- `skipValue() -> !void`

### `cbor.Config`

A struct to configure encoding and decoding behavior, such as:

- `max_string_length`
- `max_collection_size`
- `max_depth`
- `validate_utf8`
- `use_simd`

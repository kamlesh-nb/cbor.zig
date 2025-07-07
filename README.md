# Zig CBOR Library

A comprehensive, production-ready CBOR (Concise Binary Object Representation) serialization/deserialization library for Zig that strictly adheres to RFC 7049 specification.

## ✨ Features

- **🎯 Full CBOR Compliance** - Strict adherence to RFC 7049 specification
- **🚀 High Performance** - Efficient encoding/decoding with minimal allocations
- **🛡️ Memory Safe** - Proper allocation/deallocation with comprehensive error handling
- **📦 ArrayList Support** - Full support for ArrayList<T> including ArrayList<Struct>
- **🔍 Field Extraction** - Efficient selective access to fields without full deserialization
- **♾️ Indefinite-Length Collections** - Support for indefinite-length arrays and maps
- **🧪 Production Ready** - 34+ comprehensive tests covering all scenarios
- **🎨 Zero Dependencies** - Built with Zig standard library only

## 📋 Supported Types

| Type                       | Support | Description                                |
| -------------------------- | ------- | ------------------------------------------ |
| **Integers**               | ✅      | u8, u16, u32, u64, i8, i16, i32, i64       |
| **Floats**                 | ✅      | f32, f64                                   |
| **Booleans**               | ✅      | true, false                                |
| **Null**                   | ✅      | void type                                  |
| **Strings**                | ✅      | UTF-8 strings with full Unicode support    |
| **Arrays**                 | ✅      | Fixed arrays and slices                    |
| **Structs**                | ✅      | Nested structs and maps                    |
| **ArrayList**              | ✅      | ArrayList<T> including ArrayList<Struct>   |
| **Indefinite Collections** | ✅      | Indefinite-length arrays and maps          |
| **Field Extraction**       | ✅      | Selective field access without full decode |

## 🚀 Quick Start

### Basic Usage

```zig
const std = @import("std");
const cbor = @import("cbor.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize CBOR instance
    var cbor_instance = cbor.CBOR.init(allocator);
    defer cbor_instance.deinit();

    // Encode a simple value
    const value = 42;
    const encoded = try cbor_instance.encode(value);
    defer allocator.free(encoded);

    // Decode it back
    const decoded = try cbor_instance.decode(u32, encoded);
    std.debug.print("Decoded: {}\n", .{decoded}); // Output: 42
}
```

### Struct Encoding/Decoding

```zig
const Person = struct {
    id: u64,
    name: []u8,
    age: u32,
    active: bool,
};

const person = Person{
    .id = 12345,
    .name = @constCast("Alice"),
    .age = 30,
    .active = true,
};

// Initialize CBOR instance
var cbor_instance = cbor.CBOR.init(allocator);
defer cbor_instance.deinit();

// Encode
const data = try cbor_instance.encode(person);
defer allocator.free(data);

// Decode
const decoded = try cbor_instance.decode(Person, data);
defer allocator.free(decoded.name);
```

### ArrayList Support

```zig
const ArrayList = std.ArrayList;

// Create ArrayList
var scores = ArrayList(u32).init(allocator);
defer scores.deinit();
try scores.append(95);
try scores.append(87);
try scores.append(92);

// Initialize CBOR instance
var cbor_instance = cbor.CBOR.init(allocator);
defer cbor_instance.deinit();

// Encode ArrayList
const data = try cbor_instance.encode(scores);
defer allocator.free(data);

// Decode ArrayList
var decoded = try cbor_instance.decode(ArrayList(u32), data);
defer decoded.deinit();
```

### ArrayList of Structs

```zig
const Address = struct {
    street: []u8,
    city: []u8,
    zipcode: []u8,
};

const Person = struct {
    name: []u8,
    addresses: ArrayList(Address),
};

// Create person with multiple addresses
var addresses = ArrayList(Address).init(allocator);
defer addresses.deinit();

try addresses.append(Address{
    .street = @constCast("123 Main St"),
    .city = @constCast("New York"),
    .zipcode = @constCast("10001"),
});

const person = Person{
    .name = @constCast("John"),
    .addresses = addresses,
};

// Initialize CBOR instance
var cbor_instance = cbor.CBOR.init(allocator);
defer cbor_instance.deinit();

// Encode/decode works seamlessly!
const data = try cbor_instance.encode(person);
defer allocator.free(data);
```

### Field Extraction (High Performance)

```zig
// Extract specific fields without full deserialization
const user_id = try cbor_instance.extractField(u64, data, "user_id");
const username = try cbor_instance.extractField([]u8, data, "username");

if (user_id != null and username != null) {
    defer allocator.free(username.?);
    std.debug.print("User: {} - {s}\n", .{ user_id.?, username.? });
}
```

### Indefinite-Length Collections

```zig
const numbers = [_]u32{ 100, 200, 300 };

// Initialize CBOR instance
var cbor_instance = cbor.CBOR.init(allocator);
defer cbor_instance.deinit();

// Encode indefinite-length array
const data = try cbor_instance.encodeIndefiniteArray(numbers);
defer allocator.free(data);

// Decode indefinite-length array
const decoded = try cbor_instance.decodeIndefiniteArray(u32, data);
defer allocator.free(decoded);
var decoder = cbor.Decoder.init(stream.reader().any(), allocator);
const decoded = try decoder.decodeIndefiniteArray(u32);
defer allocator.free(decoded);
```

## 🏗️ Building and Testing

### Build

```bash
# Build the library
zig build

# Run the comprehensive demo
zig run src/main.zig
```

### Testing

```bash
# Run all tests (34+ comprehensive tests)
zig test src/cbor.zig

# Tests cover:
# - All basic types
# - Arrays and structs
# - ArrayList and ArrayList<Struct>
# - Field extraction
# - Indefinite-length collections
# - Error handling and edge cases
# - Memory safety
```

## 📊 Performance

- **Minimal Allocations** - Only allocates when necessary
- **Zero-Copy Field Extraction** - Access fields without full deserialization
- **Efficient ArrayList Support** - Automatic detection and handling
- **Memory Safe** - Proper cleanup even on errors
- **Fast Encoding/Decoding** - Optimized for performance

## 🔧 API Reference

### Core API - CBOR Struct

The modern, recommended API uses a CBOR struct instance:

```zig
var cbor_instance = cbor.CBOR.init(allocator);
defer cbor_instance.deinit();
```

#### `cbor_instance.encode(value: anytype) ![]u8`

Encodes any supported value to CBOR bytes.

#### `cbor_instance.decode(T: type, data: []const u8) !T`

Decodes CBOR bytes to the specified type.

#### `cbor_instance.extractField(T: type, data: []const u8, field_name: []const u8) !?T`

Extracts a specific field from CBOR data without full deserialization.

### Advanced API - Indefinite-Length Collections

#### `cbor_instance.encodeIndefiniteArray(items: anytype) ![]u8`

Encodes an indefinite-length array to CBOR bytes.

#### `cbor_instance.decodeIndefiniteArray(T: type, data: []const u8) ![]T`

Decodes an indefinite-length array from CBOR bytes.

#### `cbor_instance.encodeIndefiniteMap(value: anytype) ![]u8`

Encodes an indefinite-length map to CBOR bytes.

#### `cbor_instance.decodeIndefiniteMap(T: type, data: []const u8) !T`

Decodes an indefinite-length map from CBOR bytes.

## 🛡️ Error Handling

The library provides comprehensive error handling:

```zig
const CborError = error{
    InvalidMajorType,
    InvalidAdditionalInfo,
    UnexpectedEndOfInput,
    InvalidUtf8,
    IntegerOverflow,
    UnsupportedType,
    MalformedIndefiniteLength,
    TruncatedIndefiniteLength,
    InvalidBreakCode,
    AllocationFailure,
    OutOfMemory,
    // ... and more
};
```

## 🔍 CBOR Specification Compliance

This library strictly follows RFC 7049:

- ✅ **Major Types 0-7** - All CBOR major types supported
- ✅ **Additional Information** - Proper handling of all additional info values
- ✅ **Indefinite-Length Items** - Full support with break codes
- ✅ **UTF-8 Validation** - Proper string validation
- ✅ **Canonical Encoding** - Generates canonical CBOR when possible
- ❌ **Enums/Unions** - Intentionally not supported (not in CBOR spec)

## 📈 Memory Management

- **Allocation Strategy** - Only allocates for variable-size types (strings, arrays, ArrayLists)
- **Cleanup** - Proper deallocation with defer statements
- **Error Safety** - Memory cleanup even on decoding errors
- **ArrayList Handling** - Automatic memory management for ArrayList<T>

## 🎨 CBOR Byte Visualization

The demo includes hex visualization of CBOR bytes:

```
CBOR bytes (28 bytes): A3 61 78 FA 40 48 F5 C3 61 79 FA C0 2D 70 A4 65
                       6C 61 62 65 6C 66 4F 72 69 67 69 6E
```

## 🚨 Known Limitations

1. **No Enum/Union Support** - By design, as these are not part of the CBOR specification
2. **No Streaming** - Currently loads entire CBOR data into memory
3. **No Custom Types** - Only supports Zig built-in types and structs

## 🤝 Contributing

Contributions are welcome! Please ensure:

1. All tests pass: `zig test src/cbor.zig`
2. Follow existing code style
3. Add tests for new features

## 📄 License

MIT License - see LICENSE file for details.

## 🔗 References

- [RFC 7049 - CBOR Specification](https://tools.ietf.org/html/rfc7049)
- [CBOR.io](https://cbor.io/) - CBOR tools and resources

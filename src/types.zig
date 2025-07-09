const std = @import("std");

pub const MajorType = enum(u3) {
    unsigned_integer = 0,
    negative_integer = 1,
    byte_string = 2,
    text_string = 3,
    array = 4,
    map = 5,
    // tag = 6, // Removed tag support
    float_simple = 7,
};

pub const SimpleValue = enum(u5) {
    false = 20,
    true = 21,
    null = 22,
    undefined_value = 23,
    // Additional standard simple values
    reserved_24 = 24,
    half_float = 25,
    single_float = 26,
    double_float = 27,
    unassigned_28 = 28,
    unassigned_29 = 29,
    unassigned_30 = 30,
    unassigned_31 = 31,
    // Values 32-255 are unassigned simple values
};

pub const CborError = error{
    BufferOverflow,
    BufferUnderflow,
    TypeMismatch,
    InvalidLength,
    DepthExceeded,
    InvalidFloat,
    InvalidBool,
    IoError,
    // Enhanced error types for more specific diagnostics
    // InvalidTag, // Removed tag support
    InvalidUtf8,
    InvalidBreakCode,
    InvalidSimpleValue,
    InvalidIndefiniteLength,
    UnsupportedValue,
    IntegerOverflow,
    NegativeIntegerForUnsigned,
    MalformedInput,
    UnexpectedEof,
    OutOfMemory,
};

pub const Config = struct {
    max_string_length: u32 = 1 << 16, // 64KB
    max_collection_size: u64 = 1 << 20, // 1M
    max_depth: u8 = 32, // Max nesting
    stream_buffer_size: usize = 4096, // Streaming buffer

    // Enhanced configuration options
    enable_indefinite_length: bool = true, // Support for indefinite-length items
    // enable_tags: bool = true, // Removed tag support
    validate_utf8: bool = true, // Validate UTF-8 strings during decoding
    canonical_format: bool = false, // Use canonical CBOR encoding (RFC 8949 Section 4.2)
    allow_duplicate_keys: bool = true, // Allow duplicate keys in maps
    use_simd: bool = true, // Enable SIMD operations when available
    allocator_capacity_hint: ?usize = null, // Hint for arena allocator initial capacity
};

// Helper structures and functions
pub const InitialByte = packed struct(u8) {
    additional_info: u5, // Bits 0-4
    major_type: u3, // Bits 5-7
};

pub const LengthEncoding = struct {
    additional_info: u5,
    extra_bytes: u8,
};

pub const length_encodings = init: {
    var table: [5]LengthEncoding = undefined;
    table[0] = .{ .additional_info = 0, .extra_bytes = 0 }; // < 24
    table[1] = .{ .additional_info = 24, .extra_bytes = 1 }; // <= 0xFF
    table[2] = .{ .additional_info = 25, .extra_bytes = 2 }; // <= 0xFFFF
    table[3] = .{ .additional_info = 26, .extra_bytes = 4 }; // <= 0xFFFFFFFF
    table[4] = .{ .additional_info = 27, .extra_bytes = 8 }; // <= u64
    break :init table;
};

// Helper function to detect ArrayList types
pub fn isArrayList(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    return @hasField(T, "items") and @hasField(T, "capacity") and @hasDecl(T, "append");
}

pub fn validateType(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int, .float, .bool, .void => {},
        .optional => |opt| validateType(opt.child),
        .array => |arr| validateType(arr.child),
        .pointer => |ptr| {
            // Only allow various slice types for CBOR encoding
            if (ptr.child != u8) {
                // For development, allow other pointer types but warn
                // @compileError("Only []const u8 and []u8 slices are supported");
            }
        },
        .@"struct" => |s| {
            inline for (s.fields) |field| {
                validateType(field.type);
            }
        },
        else => {}, // Allow all types for development
    }
}

pub fn estimateSize(comptime T: type, value: anytype) usize {
    switch (@typeInfo(T)) {
        .int => {
            const v = @as(u64, @intCast(@max(value, 0)));
            return if (v < 24) 1 else if (v <= 0xFF) 2 else if (v <= 0xFFFF) 3 else if (v <= 0xFFFFFFFF) 5 else 9;
        },
        .float => return if (T == f32) 5 else 9,
        .bool, .void => return 1,
        .optional => |opt| {
            return if (value) |v| estimateSize(opt.child, v) else 1;
        },
        .array => |arr| {
            var size: usize = if (value.len < 24) 1 else if (value.len <= 0xFF) 2 else if (value.len <= 0xFFFF) 3 else 5;
            inline for (value) |item| {
                const item_size = estimateSize(arr.child, item);
                // Protect against overflow
                if (size > std.math.maxInt(usize) - item_size) {
                    return std.math.maxInt(usize);
                }
                size += item_size;
            }
            return size;
        },
        .pointer => |ptr| {
            // Handle slice of bytes
            if (ptr.child == u8 and ptr.is_const) {
                const len = value.len;
                return (if (len < 24) 1 else if (len <= 0xFF) 2 else if (len <= 0xFFFF) 3 else 5) + len;
            }
            @compileError("Unsupported pointer type");
        },
        .@"struct" => |s| {
            var size: usize = if (s.fields.len < 24) 1 else if (s.fields.len <= 0xFF) 2 else 3;
            inline for (s.fields) |field| {
                size += estimateSize([]const u8, field.name);
                size += estimateSize(field.type, @field(value, field.name));
            }
            return size;
        },
        else => @compileError("Unsupported type"),
    }
}

// Constants for indefinite-length encoding and break code
pub const INDEFINITE_LENGTH: u5 = 31;
pub const BREAK_MARKER: u8 = 0xFF;

const std = @import("std");
const simd_ops = @import("simd_ops.zig");

// SIMD utility functions for performance optimization
pub const Simd = struct {
    // We need to use comptime for function pointers
    const ops = simd_ops.getOptimizedOps();

    // Check if SIMD is supported on the current platform
    pub fn isSupported() bool {
        const arch = @import("builtin").cpu.arch;
        return (arch == .x86_64 or arch == .aarch64);
    }

    // SIMD-optimized memory copy using the best available implementation
    pub fn copyBytes(dst: []u8, src: []const u8) void {
        if (!isSupported() or src.len < 32) {
            @memcpy(dst[0..src.len], src);
            return;
        }

        ops.copy(dst, src);
    }

    // SIMD-accelerated UTF-8 validation using the best available implementation
    pub fn validateUtf8(str: []const u8) bool {
        if (!isSupported() or str.len < 32) {
            // Fallback validation for short strings
            return std.unicode.utf8ValidateSlice(str);
        }

        return ops.validate_utf8(str);
    }

    // SIMD-optimized integer array encoding
    pub fn encodeIntArray(comptime T: type, dst: []u8, src: []const T) ?usize {
        if (!isSupported() or src.len < 8 or dst.len < src.len * @sizeOf(T)) {
            return null; // Fall back to scalar implementation
        }

        // This is a placeholder for future SIMD integer array encoding
        // Currently not implemented in simd_ops
        return null;
    }
};

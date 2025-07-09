const std = @import("std");

// SIMD-optimized operations for zbor.zig

// Function signature for SIMD copy operation
pub const SimdCopyFn = fn (dst: []u8, src: []const u8) void;

// Function signature for SIMD UTF-8 validation
pub const SimdUtf8ValidateFn = fn (slice: []const u8) bool;

pub const SimdOps = struct {
    copy: SimdCopyFn,
    validate_utf8: SimdUtf8ValidateFn,

    // Fallback (non-SIMD) implementations
    fn fallbackCopy(dst: []u8, src: []const u8) void {
        @memcpy(dst[0..src.len], src);
    }

    fn fallbackUtf8Validate(slice: []const u8) bool {
        return std.unicode.utf8ValidateSlice(slice);
    }

    // Get the best SIMD implementation for the current CPU
    pub fn getBestImplementation() SimdOps {
        const target = @import("builtin").cpu.arch;

        if (comptime target == .x86_64) {
            if (comptime std.Target.x86.hasFeature(std.Target.x86.Feature.avx2)) {
                return .{
                    .copy = avx2Copy,
                    .validate_utf8 = avx2Utf8Validate,
                };
            } else if (comptime std.Target.x86.hasFeature(std.Target.x86.Feature.sse2)) {
                return .{
                    .copy = sse2Copy,
                    .validate_utf8 = sse2Utf8Validate,
                };
            }
        } else if (comptime target == .aarch64) {
            // ARM64 always has NEON
            return .{
                .copy = neonCopy,
                .validate_utf8 = neonUtf8Validate,
            };
        }

        // Fallback to non-SIMD implementation
        return .{
            .copy = fallbackCopy,
            .validate_utf8 = fallbackUtf8Validate,
        };
    }

    // x86_64 AVX2 implementations
    fn avx2Copy(dst: []u8, src: []const u8) void {
        // This would use AVX2 intrinsics for optimized copy
        // For example, using 256-bit registers to copy 32 bytes at a time
        //
        // For now, fall back to the standard copy
        fallbackCopy(dst, src);
    }

    fn avx2Utf8Validate(slice: []const u8) bool {
        // This would use AVX2 intrinsics for fast UTF-8 validation
        // For now, fall back to the standard validation
        return fallbackUtf8Validate(slice);
    }

    // x86_64 SSE2 implementations
    fn sse2Copy(dst: []u8, src: []const u8) void {
        // This would use SSE2 intrinsics for optimized copy
        // For now, fall back to the standard copy
        fallbackCopy(dst, src);
    }

    fn sse2Utf8Validate(slice: []const u8) bool {
        // This would use SSE2 intrinsics for UTF-8 validation
        // For now, fall back to the standard validation
        return fallbackUtf8Validate(slice);
    }

    // ARM64 NEON implementations
    fn neonCopy(dst: []u8, src: []const u8) void {
        // This would use NEON intrinsics for optimized copy
        // For now, fall back to the standard copy
        fallbackCopy(dst, src);
    }

    fn neonUtf8Validate(slice: []const u8) bool {
        // This would use NEON intrinsics for UTF-8 validation
        // For now, fall back to the standard validation
        return fallbackUtf8Validate(slice);
    }
};

// Helper for runtime selection of best SIMD implementation
pub fn getOptimizedOps() SimdOps {
    return SimdOps.getBestImplementation();
}

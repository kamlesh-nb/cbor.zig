const cbor = @import("cbor.zig");

pub const MajorType = cbor.MajorType;
pub const SimpleValue = cbor.SimpleValue;
pub const BREAK_STOP_CODE = cbor.BREAK_STOP_CODE;
pub const CborError = cbor.CborError;
pub const Config = cbor.Config;
pub const CBOR = cbor.CBOR;
pub const Encoder = cbor.Encoder;
pub const Decoder = cbor.Decoder;

test {
    @import("std").testing.refAllDecls(@This());
}

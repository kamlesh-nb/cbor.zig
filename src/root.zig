const cbor = @import("cbor.zig");

pub const MajorType = cbor.MajorType;
pub const SimpleValue = cbor.SimpleValue;
pub const CborError = cbor.CborError;
pub const Config = cbor.Config;
pub const Encoder = cbor.Encoder;
pub const Decoder = cbor.Decoder;
pub const CBOR = cbor.CBOR;

// Additional exports
pub const encodeEnum = cbor.encodeEnum;

test {
    @import("std").testing.refAllDecls(@This());
}

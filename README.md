# CBOR.zig

A CBOR (Concise Binary Object Representation) implementation for Zig, mostly compliant with RFC 8949.

## Features

- Supports integers, strings, arrays, maps, floats, and structs.

## Installation

Add the package to your `build.zig.zon`:

```zig
.dependencies = .{
    .cbor = .{
        .url = "https://github.com/kamlesh-nb/cbor.zig/archive/refs/tags/<version>.tar.gz",
    },
},
```

Then, add the module to your `build.zig`:

```zig
    const cbor = b.dependency("cbor", .{});

    const exe = b.addExecutable(.{
        .name = "<name>",
        .root_module = exe_mod,
    });

    exe.root_module.addImport("cbor", cbor.module("cbor"));
```

## Basic Usage

```zig
const std = @import("std");
const Serde = @import("cbor.zig").Serde;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

    const orig_person = Person{
        .name = "Lala Amarnath",
        .age = 130,
        .addresses = try allocator.dupe(Address, &[_]Address{
            Address{ .street = "I don't know", .city = "Amritsar" },
            Address{ .street = "Again I don't know", .city = "New Delhi" },
        }),
    };

    defer allocator.free(orig_person.addresses);

    const serialized = try serde.serialize(orig_person);
    defer allocator.free(serialized);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    std.debug.print("\n==================Original Person==================\n", .{});
    std.debug.print("Name: {s}\n", .{orig_person.name});
    std.debug.print("Age: {d}\n", .{orig_person.age});
    for (orig_person.addresses) |address| {
        std.debug.print("Address: {s}, {s}\n", .{ address.street, address.city });
    }

    const deserialized_person = try serde.deserialize(serialized, Person);
    std.debug.print("\n==================Deserialized Person==================\n", .{});
    std.debug.print("Name: {s}\n", .{deserialized_person.name});
    std.debug.print("Age: {d}\n", .{deserialized_person.age});
    for (deserialized_person.addresses) |address| {
        std.debug.print("Address: {s}, {s}\n", .{ address.street, address.city });
    }
}

```

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{
    EmptyInput,
    InvalidBase64,
    MissingPrivateKeyScalar,
};

/// Decode APPSTORE_CONNECT_API_KEY content to a raw 32-byte P-256 secret scalar.
///
/// Supported forms:
/// 1. Base64(encoded PEM file)
/// 2. Base64(encoded DER)
/// 3. PEM text directly
/// 4. DER bytes directly
pub fn decodePrivateKeyFromEnv(allocator: Allocator, key_input: []const u8) (Allocator.Error || Error)![32]u8 {
    if (std.mem.trim(u8, key_input, " \t\r\n").len == 0) {
        return Error.EmptyInput;
    }

    const outer = decodeOuter(allocator, key_input) catch try allocator.dupe(u8, key_input);
    defer allocator.free(outer);

    const candidate = std.mem.trim(u8, outer, " \t\r\n");
    const der = if (std.mem.indexOf(u8, candidate, "-----BEGIN") != null)
        try decodePem(allocator, candidate)
    else
        decodeBase64Auto(allocator, candidate) catch try allocator.dupe(u8, candidate);
    defer allocator.free(der);

    return extractPrivateScalar(der);
}

fn decodeOuter(allocator: Allocator, source: []const u8) (Allocator.Error || Error)![]u8 {
    return decodeBase64Auto(allocator, source);
}

fn decodePem(allocator: Allocator, pem_text: []const u8) (Allocator.Error || Error)![]u8 {
    var lines = std.mem.splitScalar(u8, pem_text, '\n');
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);

    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "-----")) continue;
        try body.appendSlice(allocator, line);
    }

    if (body.items.len == 0) return Error.InvalidBase64;

    return decodeBase64Auto(allocator, body.items);
}

fn decodeBase64Auto(allocator: Allocator, source: []const u8) (Allocator.Error || Error)![]u8 {
    const compact = try removeWhitespace(allocator, source);
    defer allocator.free(compact);

    if (compact.len == 0) return Error.InvalidBase64;

    return decodeWithCodec(allocator, std.base64.standard, compact) catch
        decodeWithCodec(allocator, std.base64.standard_no_pad, compact) catch
        decodeWithCodec(allocator, std.base64.url_safe, compact) catch
        decodeWithCodec(allocator, std.base64.url_safe_no_pad, compact) catch
        Error.InvalidBase64;
}

fn decodeWithCodec(
    allocator: Allocator,
    comptime codecs: std.base64.Codecs,
    source: []const u8,
) (Allocator.Error || Error)![]u8 {
    const decoded_len = codecs.Decoder.calcSizeForSlice(source) catch return Error.InvalidBase64;
    const out = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(out);

    codecs.Decoder.decode(out, source) catch return Error.InvalidBase64;
    return out;
}

fn removeWhitespace(allocator: Allocator, source: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    for (source) |c| {
        if (std.ascii.isWhitespace(c)) continue;
        try out.append(allocator, c);
    }

    return out.toOwnedSlice(allocator);
}

fn extractPrivateScalar(der: []const u8) Error![32]u8 {
    var idx: usize = 0;
    while (idx + 34 <= der.len) : (idx += 1) {
        if (der[idx] == 0x04 and der[idx + 1] == 0x20) {
            var key: [32]u8 = undefined;
            @memcpy(&key, der[idx + 2 .. idx + 34]);
            return key;
        }
    }

    return Error.MissingPrivateKeyScalar;
}

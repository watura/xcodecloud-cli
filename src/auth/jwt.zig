const std = @import("std");
const pem = @import("pem.zig");

const Allocator = std.mem.Allocator;
const Scheme = std.crypto.sign.ecdsa.EcdsaP256Sha256;

pub const Credentials = struct {
    issuer_id: []u8,
    key_id: []u8,
    private_key: [32]u8,
};

pub fn loadCredentialsFromEnv(allocator: Allocator) !Credentials {
    const issuer_id = try std.process.getEnvVarOwned(allocator, "APPSTORE_CONNECT_API_ISSUER_ID");
    errdefer allocator.free(issuer_id);

    const key_id = try std.process.getEnvVarOwned(allocator, "APPSTORE_CONNECT_API_KEY_ID");
    errdefer allocator.free(key_id);

    const key_value = try std.process.getEnvVarOwned(allocator, "APPSTORE_CONNECT_API_KEY");
    defer allocator.free(key_value);

    const private_key = try pem.decodePrivateKeyFromEnv(allocator, key_value);

    return .{
        .issuer_id = issuer_id,
        .key_id = key_id,
        .private_key = private_key,
    };
}

pub fn deinitCredentials(allocator: Allocator, creds: *Credentials) void {
    allocator.free(creds.issuer_id);
    allocator.free(creds.key_id);
    creds.* = undefined;
}

pub fn generateToken(allocator: Allocator, creds: Credentials, now_seconds: i64) ![]u8 {
    const iat: i64 = now_seconds;
    const exp: i64 = now_seconds + 1200;

    const header_json = try std.fmt.allocPrint(
        allocator,
        "{{\"alg\":\"ES256\",\"kid\":\"{s}\",\"typ\":\"JWT\"}}",
        .{creds.key_id},
    );
    defer allocator.free(header_json);

    const payload_json = try std.fmt.allocPrint(
        allocator,
        "{{\"iss\":\"{s}\",\"iat\":{d},\"exp\":{d},\"aud\":\"appstoreconnect-v1\"}}",
        .{ creds.issuer_id, iat, exp },
    );
    defer allocator.free(payload_json);

    const encoded_header = try base64UrlEncodeAlloc(allocator, header_json);
    defer allocator.free(encoded_header);

    const encoded_payload = try base64UrlEncodeAlloc(allocator, payload_json);
    defer allocator.free(encoded_payload);

    const signing_input = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}",
        .{ encoded_header, encoded_payload },
    );
    defer allocator.free(signing_input);

    const secret_key = try Scheme.SecretKey.fromBytes(creds.private_key);
    const key_pair = try Scheme.KeyPair.fromSecretKey(secret_key);
    const signature = try key_pair.sign(signing_input, null);

    const raw_signature = signature.toBytes();
    const encoded_signature = try base64UrlEncodeAlloc(allocator, &raw_signature);
    defer allocator.free(encoded_signature);

    return std.fmt.allocPrint(
        allocator,
        "{s}.{s}.{s}",
        .{ encoded_header, encoded_payload, encoded_signature },
    );
}

fn base64UrlEncodeAlloc(allocator: Allocator, data: []const u8) Allocator.Error![]u8 {
    const out_len = std.base64.url_safe_no_pad.Encoder.calcSize(data.len);
    const out = try allocator.alloc(u8, out_len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, data);
    return out;
}

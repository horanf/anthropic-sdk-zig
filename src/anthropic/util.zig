const std = @import("std");
const constants = @import("constants.zig");

pub fn resolveApiKey(allocator: std.mem.Allocator, api_key: ?[]const u8) ![]u8 {
    if (api_key) |value| {
        return allocator.dupe(u8, value);
    }

    return std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => error.MissingApiKey,
        else => |other| other,
    };
}

pub fn resolveBaseUrl(allocator: std.mem.Allocator, base_url: ?[]const u8) ![]u8 {
    var env_value: ?[]u8 = null;
    defer if (env_value) |value| allocator.free(value);

    const raw_value = if (base_url) |value|
        value
    else blk: {
        env_value = std.process.getEnvVarOwned(allocator, "ANTHROPIC_BASE_URL") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk constants.default_base_url,
            else => |other| return other,
        };
        break :blk env_value.?;
    };

    const normalized = std.mem.trimRight(u8, raw_value, "/");
    return allocator.dupe(u8, normalized);
}

pub fn isSuccessStatus(status: std.http.Status) bool {
    const code = @intFromEnum(status);
    return code >= 200 and code < 300;
}

pub fn copyHeader(
    allocator: std.mem.Allocator,
    head: std.http.Client.Response.Head,
    name: []const u8,
) !?[]u8 {
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            const value = try allocator.dupe(u8, header.value);
            return value;
        }
    }
    return null;
}

pub fn allocDecompressBuffer(
    allocator: std.mem.Allocator,
    content_encoding: std.http.ContentEncoding,
) ![]u8 {
    return switch (content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => error.UnsupportedCompressionMethod,
    };
}

pub fn trimTrailingCarriageReturn(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

pub fn readResponseBody(allocator: std.mem.Allocator, response: *std.http.Client.Response) ![]u8 {
    var transfer_buffer: [1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const decompress_buffer = try allocDecompressBuffer(allocator, response.head.content_encoding);
    defer if (decompress_buffer.len > 0) allocator.free(decompress_buffer);

    const reader = response.readerDecompressing(
        &transfer_buffer,
        &decompress,
        decompress_buffer,
    );
    return reader.allocRemaining(allocator, .limited(constants.max_response_body_bytes));
}

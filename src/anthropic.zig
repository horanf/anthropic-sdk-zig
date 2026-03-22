const std = @import("std");

pub const default_base_url = "https://api.anthropic.com";
pub const default_anthropic_version = "2023-06-01";
pub const default_user_agent = "anthropic-sdk-zig/0.1.0";
pub const max_response_body_bytes = 32 * 1024 * 1024;

pub const ClientOptions = struct {
    api_key: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    anthropic_version: []const u8 = default_anthropic_version,
    user_agent: []const u8 = default_user_agent,
};

pub const Role = enum {
    user,
    assistant,

    pub fn jsonStringify(self: Role, jw: anytype) !void {
        try jw.write(@tagName(self));
    }
};

pub const MessageParam = struct {
    role: Role,
    content: []const u8,
};

pub const CreateMessageRequest = struct {
    model: []const u8,
    max_tokens: usize,
    messages: []const MessageParam,
    system: ?[]const u8 = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    top_k: ?u32 = null,
    stop_sequences: ?[]const []const u8 = null,

    pub fn jsonStringify(self: CreateMessageRequest, jw: anytype) !void {
        try jw.beginObject();

        try jw.objectField("model");
        try jw.write(self.model);

        try jw.objectField("max_tokens");
        try jw.write(self.max_tokens);

        try jw.objectField("messages");
        try jw.write(self.messages);

        if (self.system) |system| {
            try jw.objectField("system");
            try jw.write(system);
        }

        if (self.temperature) |temperature| {
            try jw.objectField("temperature");
            try jw.write(temperature);
        }

        if (self.top_p) |top_p| {
            try jw.objectField("top_p");
            try jw.write(top_p);
        }

        if (self.top_k) |top_k| {
            try jw.objectField("top_k");
            try jw.write(top_k);
        }

        if (self.stop_sequences) |stop_sequences| {
            try jw.objectField("stop_sequences");
            try jw.write(stop_sequences);
        }

        try jw.endObject();
    }
};

pub const ContentBlock = struct {
    type: []const u8,
    text: ?[]const u8 = null,
};

pub const Usage = struct {
    input_tokens: usize,
    output_tokens: usize,
    cache_creation_input_tokens: ?usize = null,
    cache_read_input_tokens: ?usize = null,
};

pub const Message = struct {
    id: []const u8,
    type: []const u8,
    role: []const u8,
    content: []const ContentBlock,
    model: []const u8,
    stop_reason: ?[]const u8 = null,
    stop_sequence: ?[]const u8 = null,
    usage: Usage,
};

pub const ApiErrorBody = struct {
    type: []const u8,
    message: []const u8,
};

pub const ApiErrorEnvelope = struct {
    type: []const u8,
    @"error": ApiErrorBody,
    request_id: ?[]const u8 = null,
};

pub const MessageResponse = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(Message),
    request_id: ?[]u8,

    pub fn deinit(self: *MessageResponse) void {
        if (self.request_id) |request_id| {
            self.allocator.free(request_id);
        }
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn text(self: *const MessageResponse, allocator: std.mem.Allocator) ![]u8 {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(allocator);

        for (self.parsed.value.content) |block| {
            if (std.mem.eql(u8, block.type, "text")) {
                if (block.text) |content_text| {
                    try buffer.appendSlice(allocator, content_text);
                }
            }
        }

        return buffer.toOwnedSlice(allocator);
    }
};

pub const ErrorResponse = struct {
    allocator: std.mem.Allocator,
    status: std.http.Status,
    parsed: std.json.Parsed(ApiErrorEnvelope),
    request_id: ?[]u8,

    pub fn deinit(self: *ErrorResponse) void {
        if (self.request_id) |request_id| {
            self.allocator.free(request_id);
        }
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn requestId(self: *const ErrorResponse) ?[]const u8 {
        return self.request_id orelse self.parsed.value.request_id;
    }

    pub fn statusCode(self: *const ErrorResponse) u16 {
        return @intFromEnum(self.status);
    }
};

pub const CreateMessageResult = union(enum) {
    ok: MessageResponse,
    api_error: ErrorResponse,

    pub fn deinit(self: *CreateMessageResult) void {
        switch (self.*) {
            .ok => |*response| response.deinit(),
            .api_error => |*response| response.deinit(),
        }
        self.* = undefined;
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    http: std.http.Client,
    api_key: []const u8,
    base_url: []const u8,
    anthropic_version: []const u8,
    user_agent: []const u8,

    pub fn init(allocator: std.mem.Allocator, options: ClientOptions) !Client {
        const api_key = try resolveApiKey(allocator, options.api_key);
        errdefer allocator.free(api_key);

        const base_url = try resolveBaseUrl(allocator, options.base_url);
        errdefer allocator.free(base_url);

        const anthropic_version = try allocator.dupe(u8, options.anthropic_version);
        errdefer allocator.free(anthropic_version);

        const user_agent = try allocator.dupe(u8, options.user_agent);
        errdefer allocator.free(user_agent);

        return .{
            .allocator = allocator,
            .http = .{ .allocator = allocator },
            .api_key = api_key,
            .base_url = base_url,
            .anthropic_version = anthropic_version,
            .user_agent = user_agent,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
        self.allocator.free(self.api_key);
        self.allocator.free(self.base_url);
        self.allocator.free(self.anthropic_version);
        self.allocator.free(self.user_agent);
        self.* = undefined;
    }

    pub fn messages(self: *Client) Messages {
        return .{ .client = self };
    }

    pub fn createMessage(self: *Client, request: CreateMessageRequest) !CreateMessageResult {
        return self.messages().create(request);
    }
};

pub const Messages = struct {
    client: *Client,

    pub fn create(self: Messages, request: CreateMessageRequest) !CreateMessageResult {
        var payload_writer: std.Io.Writer.Allocating = .init(self.client.allocator);
        defer payload_writer.deinit();
        try std.json.Stringify.value(request, .{}, &payload_writer.writer);
        const payload = try payload_writer.toOwnedSlice();
        defer self.client.allocator.free(payload);

        const url = try std.fmt.allocPrint(self.client.allocator, "{s}/v1/messages", .{self.client.base_url});
        defer self.client.allocator.free(url);

        const uri = try std.Uri.parse(url);
        const extra_headers = [_]std.http.Header{
            .{ .name = "x-api-key", .value = self.client.api_key },
            .{ .name = "anthropic-version", .value = self.client.anthropic_version },
        };

        var http_request = try self.client.http.request(.POST, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .user_agent = .{ .override = self.client.user_agent },
            },
            .extra_headers = &extra_headers,
        });
        defer http_request.deinit();

        http_request.transfer_encoding = .{ .content_length = payload.len };
        var body_writer = try http_request.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(payload);
        try body_writer.end();
        try http_request.connection.?.flush();

        var response = try http_request.receiveHead(&.{});
        const request_id = try copyHeader(self.client.allocator, response.head, "request-id");
        errdefer if (request_id) |value| self.client.allocator.free(value);

        const response_body = try readResponseBody(self.client.allocator, &response);
        errdefer self.client.allocator.free(response_body);

        if (isSuccessStatus(response.head.status)) {
            const parsed = try std.json.parseFromSlice(Message, self.client.allocator, response_body, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
            self.client.allocator.free(response_body);

            return .{
                .ok = .{
                    .allocator = self.client.allocator,
                    .parsed = parsed,
                    .request_id = request_id,
                },
            };
        }

        const parsed = try std.json.parseFromSlice(ApiErrorEnvelope, self.client.allocator, response_body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        self.client.allocator.free(response_body);

        return .{
            .api_error = .{
                .allocator = self.client.allocator,
                .status = response.head.status,
                .parsed = parsed,
                .request_id = request_id,
            },
        };
    }
};

fn resolveApiKey(allocator: std.mem.Allocator, api_key: ?[]const u8) ![]u8 {
    if (api_key) |value| {
        return allocator.dupe(u8, value);
    }

    return std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => error.MissingApiKey,
        else => |other| other,
    };
}

fn resolveBaseUrl(allocator: std.mem.Allocator, base_url: ?[]const u8) ![]u8 {
    var env_value: ?[]u8 = null;
    defer if (env_value) |value| allocator.free(value);

    const raw_value = if (base_url) |value|
        value
    else blk: {
        env_value = std.process.getEnvVarOwned(allocator, "ANTHROPIC_BASE_URL") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk default_base_url,
            else => |other| return other,
        };
        break :blk env_value.?;
    };

    const normalized = std.mem.trimRight(u8, raw_value, "/");
    return allocator.dupe(u8, normalized);
}

fn isSuccessStatus(status: std.http.Status) bool {
    const code = @intFromEnum(status);
    return code >= 200 and code < 300;
}

fn copyHeader(
    allocator: std.mem.Allocator,
    head: std.http.Client.Response.Head,
    name: []const u8,
) !?[]u8 {
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            return allocator.dupe(u8, header.value);
        }
    }
    return null;
}

fn readResponseBody(allocator: std.mem.Allocator, response: *std.http.Client.Response) ![]u8 {
    var transfer_buffer: [1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;

    var decompress_buffer: []u8 = &.{};
    switch (response.head.content_encoding) {
        .identity => {},
        .zstd => {
            decompress_buffer = try allocator.alloc(u8, std.compress.zstd.default_window_len);
        },
        .deflate, .gzip => {
            decompress_buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
        },
        .compress => return error.UnsupportedCompressionMethod,
    }
    defer if (decompress_buffer.len > 0) allocator.free(decompress_buffer);

    const reader = response.readerDecompressing(
        &transfer_buffer,
        &decompress,
        decompress_buffer,
    );
    return reader.allocRemaining(allocator, .limited(max_response_body_bytes));
}

const TestServerMode = enum {
    success,
    rate_limited,
};

const TestServer = struct {
    allocator: std.mem.Allocator,
    listener: std.net.Server,
    mode: TestServerMode,
    thread: ?std.Thread = null,
    thread_error: ?anyerror = null,
    received_target: ?[]u8 = null,
    received_content_type: ?[]u8 = null,
    received_api_key: ?[]u8 = null,
    received_version: ?[]u8 = null,
    received_body: ?[]u8 = null,

    fn init(mode: TestServerMode) !TestServer {
        const address = try std.net.Address.parseIp4("127.0.0.1", 0);
        return .{
            .allocator = std.heap.page_allocator,
            .listener = try address.listen(.{ .reuse_address = true }),
            .mode = mode,
        };
    }

    fn deinit(self: *TestServer) void {
        if (self.received_target) |value| self.allocator.free(value);
        if (self.received_content_type) |value| self.allocator.free(value);
        if (self.received_api_key) |value| self.allocator.free(value);
        if (self.received_version) |value| self.allocator.free(value);
        if (self.received_body) |value| self.allocator.free(value);
        self.listener.stream.close();
        self.* = undefined;
    }

    fn start(self: *TestServer) !void {
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    fn join(self: *TestServer) !void {
        self.thread.?.join();
        self.thread = null;
        if (self.thread_error) |err| return err;
    }

    fn url(self: *const TestServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{self.listener.listen_address.getPort()});
    }

    fn threadMain(self: *TestServer) void {
        self.run() catch |err| {
            self.thread_error = err;
        };
    }

    fn run(self: *TestServer) !void {
        const connection = try self.listener.accept();
        defer connection.stream.close();

        var read_buffer: [8192]u8 = undefined;
        var write_buffer: [8192]u8 = undefined;
        var connection_reader = connection.stream.reader(&read_buffer);
        var connection_writer = connection.stream.writer(&write_buffer);
        var server = std.http.Server.init(&connection_reader.interface, &connection_writer.interface);

        var request = try server.receiveHead();
        try self.captureRequest(&request);

        switch (self.mode) {
            .success => try request.respond(
                \\{"id":"msg_test_123","type":"message","role":"assistant","content":[{"type":"text","text":"Hello from Claude."}],"model":"claude-sonnet-test","stop_reason":"end_turn","usage":{"input_tokens":12,"output_tokens":8},"ignored_field":"ok"}
            , .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "request-id", .value = "req_test_success" },
                },
            }),
            .rate_limited => try request.respond(
                \\{"type":"error","error":{"type":"rate_limit_error","message":"Too many requests"}}
            , .{
                .status = .too_many_requests,
                .extra_headers = &.{
                    .{ .name = "request-id", .value = "req_test_rate_limit" },
                },
            }),
        }
    }

    fn captureRequest(self: *TestServer, request: *std.http.Server.Request) !void {
        self.received_target = try self.allocator.dupe(u8, request.head.target);
        if (request.head.content_type) |content_type| {
            self.received_content_type = try self.allocator.dupe(u8, content_type);
        }

        var iterator = std.http.HeaderIterator.init(request.head_buffer);
        while (iterator.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "x-api-key")) {
                self.received_api_key = try self.allocator.dupe(u8, header.value);
            } else if (std.ascii.eqlIgnoreCase(header.name, "anthropic-version")) {
                self.received_version = try self.allocator.dupe(u8, header.value);
            }
        }

        var transfer_buffer: [256]u8 = undefined;
        const reader = request.readerExpectNone(&transfer_buffer);
        self.received_body = try reader.allocRemaining(self.allocator, .limited(max_response_body_bytes));
    }
};

test "messages.create sends the Claude messages request and parses the response" {
    var server = try TestServer.init(.success);
    defer server.deinit();
    try server.start();

    const base_url = try server.url(std.testing.allocator);
    defer std.testing.allocator.free(base_url);

    var client = try Client.init(std.testing.allocator, .{
        .api_key = "test-api-key",
        .base_url = base_url,
    });
    defer client.deinit();

    var result = try client.messages().create(.{
        .model = "claude-sonnet-test",
        .max_tokens = 128,
        .messages = &.{
            .{
                .role = .user,
                .content = "Hello, Claude",
            },
        },
    });
    defer result.deinit();

    try server.join();

    try std.testing.expectEqualStrings("/v1/messages", server.received_target.?);
    try std.testing.expectEqualStrings("application/json", server.received_content_type.?);
    try std.testing.expectEqualStrings("test-api-key", server.received_api_key.?);
    try std.testing.expectEqualStrings(default_anthropic_version, server.received_version.?);

    var parsed_request = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, server.received_body.?, .{});
    defer parsed_request.deinit();

    const body_object = parsed_request.value.object;
    try std.testing.expectEqualStrings("claude-sonnet-test", body_object.get("model").?.string);
    try std.testing.expectEqual(@as(i64, 128), body_object.get("max_tokens").?.integer);
    try std.testing.expect(body_object.get("system") == null);

    const messages = body_object.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqualStrings("user", messages.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("Hello, Claude", messages.items[0].object.get("content").?.string);

    switch (result) {
        .ok => |*message| {
            try std.testing.expectEqualStrings("req_test_success", message.request_id.?);
            try std.testing.expectEqualStrings("msg_test_123", message.parsed.value.id);
            try std.testing.expectEqualStrings("end_turn", message.parsed.value.stop_reason.?);

            const text = try message.text(std.testing.allocator);
            defer std.testing.allocator.free(text);
            try std.testing.expectEqualStrings("Hello from Claude.", text);
        },
        .api_error => return error.TestExpectedSuccessResponse,
    }
}

test "messages.create returns parsed Claude API errors without over-wrapping them" {
    var server = try TestServer.init(.rate_limited);
    defer server.deinit();
    try server.start();

    const base_url = try server.url(std.testing.allocator);
    defer std.testing.allocator.free(base_url);

    var client = try Client.init(std.testing.allocator, .{
        .api_key = "test-api-key",
        .base_url = base_url,
    });
    defer client.deinit();

    var result = try client.createMessage(.{
        .model = "claude-sonnet-test",
        .max_tokens = 64,
        .messages = &.{
            .{
                .role = .user,
                .content = "rate limit me",
            },
        },
    });
    defer result.deinit();

    try server.join();

    switch (result) {
        .ok => return error.TestExpectedApiErrorResponse,
        .api_error => |*api_error| {
            try std.testing.expectEqual(@as(u16, 429), api_error.statusCode());
            try std.testing.expectEqualStrings("rate_limit_error", api_error.parsed.value.@"error".type);
            try std.testing.expectEqualStrings("Too many requests", api_error.parsed.value.@"error".message);
            try std.testing.expectEqualStrings("req_test_rate_limit", api_error.requestId().?);
        },
    }
}

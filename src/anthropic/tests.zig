const std = @import("std");
const client_mod = @import("client.zig");
const constants = @import("constants.zig");
const types = @import("types.zig");

const Client = client_mod.Client;
const StreamMessageStartEvent = types.StreamMessageStartEvent;

const TestServerMode = enum {
    success,
    rate_limited,
    stream_success,
    tool_use_success,
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
            .stream_success => try request.respond(
                \\event: message_start
                \\data: {"type":"message_start","message":{"id":"msg_stream_123","type":"message","role":"assistant","content":[],"model":"claude-sonnet-test","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":12,"output_tokens":1}}}
                \\
                \\event: content_block_start
                \\data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
                \\
                \\event: ping
                \\data: {"type":"ping"}
                \\
                \\event: content_block_delta
                \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
                \\
                \\event: content_block_delta
                \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"!"}}
                \\
                \\event: content_block_stop
                \\data: {"type":"content_block_stop","index":0}
                \\
                \\event: message_delta
                \\data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":15}}
                \\
                \\event: message_stop
                \\data: {"type":"message_stop"}
                \\
            , .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "request-id", .value = "req_test_stream" },
                    .{ .name = "content-type", .value = "text/event-stream" },
                },
            }),
            .tool_use_success => try request.respond(
                \\{"id":"msg_tool_123","type":"message","role":"assistant","content":[{"type":"text","text":"I'll run bash."},{"type":"tool_use","id":"toolu_bash_123","name":"bash","input":{"command":"pwd"}}],"model":"claude-sonnet-test","stop_reason":"tool_use","usage":{"input_tokens":22,"output_tokens":12}}
            , .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "request-id", .value = "req_test_tool_use" },
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
        self.received_body = try reader.allocRemaining(
            self.allocator,
            .limited(constants.max_response_body_bytes),
        );
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
    try std.testing.expectEqualStrings(constants.default_anthropic_version, server.received_version.?);

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

test "messages.stream sends stream=true and yields Claude SSE events" {
    var server = try TestServer.init(.stream_success);
    defer server.deinit();
    try server.start();

    const base_url = try server.url(std.testing.allocator);
    defer std.testing.allocator.free(base_url);

    var client = try Client.init(std.testing.allocator, .{
        .api_key = "test-api-key",
        .base_url = base_url,
    });
    defer client.deinit();

    var result = try client.streamMessage(.{
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

    var event_count: usize = 0;
    var text_buffer: std.ArrayList(u8) = .empty;
    defer text_buffer.deinit(std.testing.allocator);

    switch (result) {
        .api_error => return error.TestExpectedStreamResult,
        .stream => |*stream| {
            try std.testing.expectEqualStrings("req_test_stream", stream.request_id.?);

            while (try stream.nextEvent()) |event| {
                event_count += 1;

                if (std.mem.eql(u8, event.event, "message_start")) {
                    var parsed = try event.json(StreamMessageStartEvent, std.testing.allocator);
                    defer parsed.deinit();
                    try std.testing.expectEqualStrings("msg_stream_123", parsed.value.message.id);
                }

                if (try event.textDelta(std.testing.allocator)) |text| {
                    defer std.testing.allocator.free(text);
                    try text_buffer.appendSlice(std.testing.allocator, text);
                }
            }
        },
    }

    try std.testing.expectEqual(@as(usize, 8), event_count);
    try std.testing.expectEqualStrings("/v1/messages", server.received_target.?);
    try std.testing.expectEqualStrings("application/json", server.received_content_type.?);
    try std.testing.expectEqualStrings(constants.default_anthropic_version, server.received_version.?);

    var parsed_request = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, server.received_body.?, .{});
    defer parsed_request.deinit();
    try std.testing.expectEqual(true, parsed_request.value.object.get("stream").?.bool);
    try std.testing.expectEqualStrings("Hello!", text_buffer.items);
}

test "messages.create supports bash tool definitions and parses tool_use content blocks" {
    var server = try TestServer.init(.tool_use_success);
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
        .max_tokens = 128,
        .tools = &.{
            .{},
        },
        .tool_choice = .{
            .tool = .{
                .name = "bash",
                .disable_parallel_tool_use = true,
            },
        },
        .messages = &.{
            .{
                .role = .user,
                .content = "Print the current directory.",
            },
        },
    });
    defer result.deinit();

    try server.join();

    var parsed_request = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, server.received_body.?, .{});
    defer parsed_request.deinit();

    const request_object = parsed_request.value.object;
    const tools = request_object.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 1), tools.items.len);
    try std.testing.expectEqualStrings("bash_20250124", tools.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("bash", tools.items[0].object.get("name").?.string);

    const tool_choice = request_object.get("tool_choice").?.object;
    try std.testing.expectEqualStrings("tool", tool_choice.get("type").?.string);
    try std.testing.expectEqualStrings("bash", tool_choice.get("name").?.string);
    try std.testing.expectEqual(true, tool_choice.get("disable_parallel_tool_use").?.bool);

    switch (result) {
        .ok => |*message| {
            try std.testing.expectEqualStrings("tool_use", message.parsed.value.stop_reason.?);
            try std.testing.expectEqual(@as(usize, 2), message.parsed.value.content.len);
            try std.testing.expectEqualStrings("text", message.parsed.value.content[0].type);
            try std.testing.expectEqualStrings("tool_use", message.parsed.value.content[1].type);
            try std.testing.expectEqualStrings("toolu_bash_123", message.parsed.value.content[1].id.?);
            try std.testing.expectEqualStrings("bash", message.parsed.value.content[1].name.?);
            try std.testing.expectEqualStrings(
                "pwd",
                message.parsed.value.content[1].input.?.object.get("command").?.string,
            );
        },
        .api_error => return error.TestExpectedSuccessResponse,
    }
}

test "messages.create serializes tool_result blocks for bash tool loops" {
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

    var result = try client.createMessage(.{
        .model = "claude-sonnet-test",
        .max_tokens = 128,
        .messages = &.{
            .{
                .role = .assistant,
                .content_blocks = &.{
                    .{ .text = .{ .text = "I'll run bash." } },
                },
            },
            .{
                .role = .user,
                .content_blocks = &.{
                    .{
                        .tool_result = .{
                            .tool_use_id = "toolu_bash_123",
                            .content = "/Users/horaoen/dev/repo/anthropic-sdk-zig\n",
                        },
                    },
                    .{ .text = .{ .text = "Continue." } },
                },
            },
        },
    });
    defer result.deinit();

    try server.join();

    var parsed_request = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, server.received_body.?, .{});
    defer parsed_request.deinit();

    const messages = parsed_request.value.object.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);

    const assistant_blocks = messages.items[0].object.get("content").?.array;
    try std.testing.expectEqualStrings("text", assistant_blocks.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("I'll run bash.", assistant_blocks.items[0].object.get("text").?.string);

    const user_blocks = messages.items[1].object.get("content").?.array;
    try std.testing.expectEqualStrings("tool_result", user_blocks.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("toolu_bash_123", user_blocks.items[0].object.get("tool_use_id").?.string);
    try std.testing.expectEqualStrings(
        "/Users/horaoen/dev/repo/anthropic-sdk-zig\n",
        user_blocks.items[0].object.get("content").?.string,
    );
    try std.testing.expectEqualStrings("text", user_blocks.items[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("Continue.", user_blocks.items[1].object.get("text").?.string);
}

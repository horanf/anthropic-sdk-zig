const std = @import("std");
const stream_mod = @import("stream.zig");
const types = @import("types.zig");
const util = @import("util.zig");

pub const MessageResponse = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(types.Message),
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
    parsed: std.json.Parsed(types.ApiErrorEnvelope),
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

pub const CreateMessageStreamResult = union(enum) {
    stream: stream_mod.MessageStream,
    api_error: ErrorResponse,

    pub fn deinit(self: *CreateMessageStreamResult) void {
        switch (self.*) {
            .stream => |*stream| stream.deinit(),
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

    pub fn init(allocator: std.mem.Allocator, options: types.ClientOptions) !Client {
        const api_key = try util.resolveApiKey(allocator, options.api_key);
        errdefer allocator.free(api_key);

        const base_url = try util.resolveBaseUrl(allocator, options.base_url);
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

    pub fn createMessage(self: *Client, request: types.CreateMessageRequest) !CreateMessageResult {
        return self.messages().create(request);
    }

    pub fn streamMessage(self: *Client, request: types.CreateMessageRequest) !CreateMessageStreamResult {
        return self.messages().stream(request);
    }
};

pub const Messages = struct {
    client: *Client,

    const StartedRequest = struct {
        request: std.http.Client.Request,
        response: std.http.Client.Response,
        request_id: ?[]u8,
    };

    pub fn create(self: Messages, request: types.CreateMessageRequest) !CreateMessageResult {
        var started = try self.beginRequest(request, false);
        defer started.request.deinit();
        errdefer if (started.request_id) |value| self.client.allocator.free(value);

        const response_body = try util.readResponseBody(self.client.allocator, &started.response);
        errdefer self.client.allocator.free(response_body);

        if (util.isSuccessStatus(started.response.head.status)) {
            return self.parseSuccessResponse(response_body, started.request_id);
        }

        return .{
            .api_error = try self.parseErrorResponse(
                started.response.head.status,
                response_body,
                started.request_id,
            ),
        };
    }

    pub fn stream(self: Messages, request: types.CreateMessageRequest) !CreateMessageStreamResult {
        var started = try self.beginRequest(request, true);
        errdefer started.request.deinit();
        errdefer if (started.request_id) |value| self.client.allocator.free(value);

        if (!util.isSuccessStatus(started.response.head.status)) {
            defer started.request.deinit();

            const response_body = try util.readResponseBody(self.client.allocator, &started.response);
            defer self.client.allocator.free(response_body);

            return .{
                .api_error = try self.parseErrorResponse(
                    started.response.head.status,
                    response_body,
                    started.request_id,
                ),
            };
        }

        const request_id = started.request_id;
        started.request_id = null;

        return .{
            .stream = try stream_mod.MessageStream.init(
                self.client.allocator,
                started.request,
                started.response,
                request_id,
            ),
        };
    }

    fn beginRequest(self: Messages, request: types.CreateMessageRequest, should_stream: bool) !StartedRequest {
        var payload_writer: std.Io.Writer.Allocating = .init(self.client.allocator);
        defer payload_writer.deinit();

        const RequestPayload = struct {
            request: types.CreateMessageRequest,
            stream: bool,

            pub fn jsonStringify(self_: @This(), jw: anytype) !void {
                try self_.request.writeJson(jw, self_.stream);
            }
        };

        try std.json.Stringify.value(
            RequestPayload{
                .request = request,
                .stream = should_stream,
            },
            .{},
            &payload_writer.writer,
        );
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
        errdefer http_request.deinit();

        http_request.transfer_encoding = .{ .content_length = payload.len };
        var body_writer = try http_request.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(payload);
        try body_writer.end();
        try http_request.connection.?.flush();

        const response = try http_request.receiveHead(&.{});
        const request_id = try util.copyHeader(self.client.allocator, response.head, "request-id");
        errdefer if (request_id) |value| self.client.allocator.free(value);

        return .{
            .request = http_request,
            .response = response,
            .request_id = request_id,
        };
    }

    fn parseSuccessResponse(
        self: Messages,
        response_body: []u8,
        request_id: ?[]u8,
    ) !CreateMessageResult {
        const parsed = try std.json.parseFromSlice(types.Message, self.client.allocator, response_body, .{
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

    fn parseErrorResponse(
        self: Messages,
        status: std.http.Status,
        response_body: []const u8,
        request_id: ?[]u8,
    ) !ErrorResponse {
        const parsed = try std.json.parseFromSlice(types.ApiErrorEnvelope, self.client.allocator, response_body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        self.client.allocator.free(response_body);

        return .{
            .allocator = self.client.allocator,
            .status = status,
            .parsed = parsed,
            .request_id = request_id,
        };
    }
};

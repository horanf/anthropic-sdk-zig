const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");

pub const ServerSentEvent = struct {
    event: []const u8,
    data: []const u8,

    pub fn json(self: ServerSentEvent, comptime T: type, allocator: std.mem.Allocator) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, allocator, self.data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    pub fn textDelta(self: ServerSentEvent, allocator: std.mem.Allocator) !?[]u8 {
        if (!std.mem.eql(u8, self.event, "content_block_delta")) {
            return null;
        }

        var parsed = try self.json(types.StreamContentBlockDeltaEvent, allocator);
        defer parsed.deinit();

        if (!std.mem.eql(u8, parsed.value.delta.type, "text_delta")) {
            return null;
        }

        const text = parsed.value.delta.text orelse return null;
        const copied = try allocator.dupe(u8, text);
        return copied;
    }
};

pub const MessageStream = struct {
    allocator: std.mem.Allocator,
    request: std.http.Client.Request,
    response: std.http.Client.Response,
    reader: *std.Io.Reader,
    request_id: ?[]u8,
    transfer_buffer: [1024]u8,
    decompress: std.http.Decompress,
    decompress_buffer: []u8,
    line_buffer: std.ArrayList(u8),
    event_buffer: std.ArrayList(u8),
    data_buffer: std.ArrayList(u8),

    pub fn init(
        allocator: std.mem.Allocator,
        request: std.http.Client.Request,
        response: std.http.Client.Response,
        request_id: ?[]u8,
    ) !MessageStream {
        var stream = MessageStream{
            .allocator = allocator,
            .request = request,
            .response = response,
            .reader = undefined,
            .request_id = request_id,
            .transfer_buffer = undefined,
            .decompress = undefined,
            .decompress_buffer = &.{},
            .line_buffer = .empty,
            .event_buffer = .empty,
            .data_buffer = .empty,
        };
        errdefer stream.deinit();

        stream.response.request = &stream.request;
        stream.decompress_buffer = try util.allocDecompressBuffer(allocator, stream.response.head.content_encoding);
        stream.reader = stream.response.readerDecompressing(
            &stream.transfer_buffer,
            &stream.decompress,
            stream.decompress_buffer,
        );

        return stream;
    }

    pub fn deinit(self: *MessageStream) void {
        if (self.request_id) |request_id| {
            self.allocator.free(request_id);
        }
        if (self.decompress_buffer.len > 0) {
            self.allocator.free(self.decompress_buffer);
        }
        self.line_buffer.deinit(self.allocator);
        self.event_buffer.deinit(self.allocator);
        self.data_buffer.deinit(self.allocator);
        self.request.deinit();
        self.* = undefined;
    }

    pub fn next(self: *MessageStream) !?ServerSentEvent {
        return self.nextEvent();
    }

    pub fn nextEvent(self: *MessageStream) !?ServerSentEvent {
        self.event_buffer.clearRetainingCapacity();
        self.data_buffer.clearRetainingCapacity();

        while (true) {
            const maybe_line = try self.readLine();
            if (maybe_line == null) {
                if (self.event_buffer.items.len == 0 and self.data_buffer.items.len == 0) {
                    return null;
                }
                return self.buildEvent();
            }

            const line = maybe_line.?;
            if (line.len == 0) {
                if (self.event_buffer.items.len == 0 and self.data_buffer.items.len == 0) {
                    continue;
                }
                return self.buildEvent();
            }

            if (line[0] == ':') {
                continue;
            }

            const colon_index = std.mem.indexOfScalar(u8, line, ':');
            const field_name = if (colon_index) |index| line[0..index] else line;
            var value = if (colon_index) |index| line[index + 1 ..] else "";
            if (value.len > 0 and value[0] == ' ') {
                value = value[1..];
            }

            if (std.mem.eql(u8, field_name, "event")) {
                self.event_buffer.clearRetainingCapacity();
                try self.event_buffer.appendSlice(self.allocator, value);
            } else if (std.mem.eql(u8, field_name, "data")) {
                if (self.data_buffer.items.len > 0) {
                    try self.data_buffer.append(self.allocator, '\n');
                }
                try self.data_buffer.appendSlice(self.allocator, value);
            }
        }
    }

    fn readLine(self: *MessageStream) !?[]const u8 {
        self.line_buffer.clearRetainingCapacity();

        var byte: [1]u8 = undefined;
        while (true) {
            const count = try self.reader.readSliceShort(&byte);
            if (count == 0) {
                if (self.line_buffer.items.len == 0) {
                    return null;
                }
                return util.trimTrailingCarriageReturn(self.line_buffer.items);
            }

            if (byte[0] == '\n') {
                return util.trimTrailingCarriageReturn(self.line_buffer.items);
            }

            try self.line_buffer.append(self.allocator, byte[0]);
        }
    }

    fn buildEvent(self: *MessageStream) ServerSentEvent {
        return .{
            .event = if (self.event_buffer.items.len == 0) "message" else self.event_buffer.items,
            .data = self.data_buffer.items,
        };
    }
};

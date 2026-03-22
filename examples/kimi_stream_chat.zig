const std = @import("std");
const anthropic = @import("anthropic_sdk_zig");

const kimi_base_url = "https://api.kimi.com/coding";
const kimi_model = "kimi-for-coding";
const max_input_bytes = 16 * 1024;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const base_url = try envOrDefault(allocator, "ANTHROPIC_BASE_URL", kimi_base_url);
    defer allocator.free(base_url);

    const model = try envOrDefault(allocator, "KIMI_MODEL", kimi_model);
    defer allocator.free(model);

    var client = anthropic.Client.init(allocator, .{
        .base_url = base_url,
    }) catch |err| switch (err) {
        error.MissingApiKey => {
            printUsage();
            return;
        },
        else => return err,
    };
    defer client.deinit();

    var messages: std.ArrayList(anthropic.MessageParam) = .empty;
    defer deinitHistory(allocator, &messages);

    var stdin_buffer: [max_input_bytes]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);

    std.debug.print(
        \\Kimi stream chat demo
        \\model: {s}
        \\base_url: {s}
        \\
        \\Commands:
        \\  /exit   quit
        \\  /clear  clear conversation history
        \\
    ,
        .{ model, base_url },
    );

    while (true) {
        std.debug.print("You> ", .{});

        const maybe_line = try stdin_reader.interface.takeDelimiter('\n');
        if (maybe_line == null) {
            std.debug.print("\n", .{});
            break;
        }

        const line = std.mem.trim(u8, maybe_line.?, " \r\t");
        if (line.len == 0) {
            continue;
        }
        if (std.mem.eql(u8, line, "/exit")) {
            break;
        }
        if (std.mem.eql(u8, line, "/clear")) {
            deinitHistory(allocator, &messages);
            messages = .empty;
            std.debug.print("history cleared\n", .{});
            continue;
        }

        const user_text = try allocator.dupe(u8, line);
        errdefer allocator.free(user_text);
        try messages.append(allocator, .{
            .role = .user,
            .content = user_text,
        });

        var remove_user_message = true;
        defer if (remove_user_message) freeLastMessage(allocator, &messages);

        std.debug.print("Kimi> ", .{});

        var result = try client.messages().stream(.{
            .model = model,
            .max_tokens = 4096,
            .messages = messages.items,
        });
        defer result.deinit();

        switch (result) {
            .api_error => |*api_error| {
                std.debug.print(
                    "status={d} type={s} message={s}\n",
                    .{
                        api_error.statusCode(),
                        api_error.parsed.value.@"error".type,
                        api_error.parsed.value.@"error".message,
                    },
                );
            },
            .stream => |*stream| {
                var assistant_text: std.ArrayList(u8) = .empty;
                defer assistant_text.deinit(allocator);

                while (try stream.nextEvent()) |event| {
                    if (try event.textDelta(allocator)) |text| {
                        defer allocator.free(text);
                        std.debug.print("{s}", .{text});
                        try assistant_text.appendSlice(allocator, text);
                    }
                }
                std.debug.print("\n", .{});

                const assistant_slice = try assistant_text.toOwnedSlice(allocator);
                errdefer allocator.free(assistant_slice);

                try messages.append(allocator, .{
                    .role = .assistant,
                    .content = assistant_slice,
                });
                remove_user_message = false;
            },
        }
    }
}

fn envOrDefault(allocator: std.mem.Allocator, name: []const u8, default_value: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => allocator.dupe(u8, default_value),
        else => |other| other,
    };
}

fn freeLastMessage(allocator: std.mem.Allocator, messages: *std.ArrayList(anthropic.MessageParam)) void {
    const message = messages.pop().?;
    if (message.content) |content| {
        allocator.free(content);
    }
}

fn deinitHistory(allocator: std.mem.Allocator, messages: *std.ArrayList(anthropic.MessageParam)) void {
    for (messages.items) |message| {
        if (message.content) |content| {
            allocator.free(content);
        }
    }
    messages.deinit(allocator);
}

fn printUsage() void {
    std.debug.print(
        \\Missing ANTHROPIC_API_KEY.
        \\
        \\For Kimi Code, either source .env or run:
        \\  export ANTHROPIC_API_KEY=sk-kimi-xxxxxxxxxxxxxxxx
        \\  export ANTHROPIC_BASE_URL=https://api.kimi.com/coding
        \\  export KIMI_MODEL=kimi-k2.5
        \\  zig build kimi-stream-chat
        \\
    ,
        .{},
    );
}

# anthropic-sdk-zig

Minimal Zig wrapper for the Anthropic Claude Messages API.

This project follows the basic usage shape of `anthropic-sdk-python`, but only implements the smallest practical surface:

- synchronous client
- `POST /v1/messages`
- basic SSE streaming support for `POST /v1/messages`
- basic tool use support focused on the Anthropic bash tool
- API key auth
- basic request/response structs
- parsed API error response

It intentionally does not implement batches, beta APIs, retries, or a full high-level stream accumulator.

## Requirements

- Zig `0.15.2`
- Anthropic API key in `ANTHROPIC_API_KEY`, or pass `api_key` explicitly

## Implemented API

The public module name is `anthropic_sdk_zig`.

Main entry points:

- `Client.init(allocator, options)`
- `client.messages().create(request)`
- `client.messages().stream(request)`
- `client.createMessage(request)`
- `client.streamMessage(request)`
- `MessageResponse.text(allocator)`
- `MessageStream.nextEvent()`
- `ServerSentEvent.json(T, allocator)`
- `BashToolDefinition`
- `ToolResultBlockParam`

Default behavior:

- reads `ANTHROPIC_API_KEY` if `ClientOptions.api_key` is not set
- reads `ANTHROPIC_BASE_URL` if `ClientOptions.base_url` is not set
- sends `anthropic-version: 2023-06-01`
- sends `content-type: application/json`

## Usage

```zig
const std = @import("std");
const anthropic = @import("anthropic_sdk_zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try anthropic.Client.init(allocator, .{});
    defer client.deinit();

    var result = try client.messages().create(.{
        .model = "claude-sonnet-4-5",
        .max_tokens = 256,
        .messages = &.{
            .{
                .role = .user,
                .content = "Hello, Claude",
            },
        },
    });
    defer result.deinit();

    switch (result) {
        .ok => |*message| {
            const text = try message.text(allocator);
            defer allocator.free(text);

            std.debug.print("request_id={s}\n{s}\n", .{
                message.request_id orelse "",
                text,
            });
        },
        .api_error => |*api_error| {
            std.debug.print("status={d} type={s} message={s}\n", .{
                api_error.statusCode(),
                api_error.parsed.value.@"error".type,
                api_error.parsed.value.@"error".message,
            });
        },
    }
}
```

## Streaming Usage

Streaming sends the same request shape with `stream: true` added internally and returns raw SSE events.

```zig
const std = @import("std");
const anthropic = @import("anthropic_sdk_zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try anthropic.Client.init(allocator, .{});
    defer client.deinit();

    var result = try client.messages().stream(.{
        .model = "claude-sonnet-4-5",
        .max_tokens = 256,
        .messages = &.{
            .{
                .role = .user,
                .content = "Hello, Claude",
            },
        },
    });
    defer result.deinit();

    switch (result) {
        .stream => |*stream| {
            while (try stream.nextEvent()) |event| {
                if (try event.textDelta(allocator)) |text| {
                    defer allocator.free(text);
                    std.debug.print("{s}", .{text});
                }
            }
            std.debug.print("\n", .{});
        },
        .api_error => |*api_error| {
            std.debug.print("status={d} type={s} message={s}\n", .{
                api_error.statusCode(),
                api_error.parsed.value.@"error".type,
                api_error.parsed.value.@"error".message,
            });
        },
    }
}
```

Example of parsing a specific event type:

```zig
const parsed = try event.json(anthropic.StreamContentBlockDeltaEvent, allocator);
defer parsed.deinit();
```

## Tool Use

This SDK now supports the minimum pieces needed for a bash tool loop:

- declare the Anthropic bash tool in `tools`
- optionally force tool choice with `tool_choice`
- parse `tool_use` content blocks from Claude responses
- send `tool_result` blocks back in the next `user` message

It does not execute bash commands for you. The SDK stays at the protocol layer.

### Requesting bash tool use

```zig
var result = try client.messages().create(.{
    .model = "claude-sonnet-4-5",
    .max_tokens = 256,
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
            .content = "Print the current working directory using bash.",
        },
    },
});
defer result.deinit();
```

When Claude chooses the tool, the response content may include a `tool_use` block:

```zig
switch (result) {
    .ok => |*message| {
        for (message.parsed.value.content) |block| {
            if (std.mem.eql(u8, block.type, "tool_use")) {
                const command = block.input.?.object.get("command").?.string;
                std.debug.print("tool={s} command={s}\n", .{
                    block.name.?,
                    command,
                });
            }
        }
    },
    .api_error => |*api_error| {
        _ = api_error;
    },
}
```

### Sending a bash tool result back

After you run the command in your own code, continue the conversation by sending a `tool_result` block first, then optional text:

```zig
_ = try client.messages().create(.{
    .model = "claude-sonnet-4-5",
    .max_tokens = 256,
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
                        .tool_use_id = "toolu_123",
                        .content = "/tmp\n",
                    },
                },
                .{ .text = .{ .text = "Continue." } },
            },
        },
    },
});
```

## Request shape

Currently supported request fields:

- `model`
- `max_tokens`
- `messages`
- `tools` for Anthropic bash tool definitions
- `tool_choice`
- `system`
- `temperature`
- `top_p`
- `top_k`
- `stop_sequences`

`messages[*].content` is currently plain text only.

If you need content blocks in input messages, use `messages[*].content_blocks`. The current implementation supports:

- `text`
- `tool_result`

For streaming requests, `stream: true` is added by `messages.stream()` and `streamMessage()`.

## Response shape

The success path parses:

- `id`
- `type`
- `role`
- `content`
- `model`
- `stop_reason`
- `stop_sequence`
- `usage`

Unknown response fields are ignored.

Response content blocks currently expose enough fields for text and client tool use:

- `type`
- `text`
- `id`
- `name`
- `input`

The error path returns the parsed Claude error envelope plus HTTP status and `request-id`.

Streaming currently exposes raw SSE events plus a few light helpers:

- `MessageStream.nextEvent()`
- `ServerSentEvent.json(T, allocator)`
- `ServerSentEvent.textDelta(allocator)`

Known typed event helpers include:

- `StreamMessageStartEvent`
- `StreamContentBlockStartEvent`
- `StreamContentBlockDeltaEvent`
- `StreamContentBlockStopEvent`
- `StreamMessageDeltaEvent`
- `StreamMessageStopEvent`
- `StreamPingEvent`

## Build

```sh
zig build
zig build test
```

## Notes

- This package is a library first. The bundled executable only prints a placeholder message.
- The current implementation is designed to stay close to the wire format instead of adding extra abstraction layers.
- Streaming support is intentionally thin: it does not yet accumulate a final `Message` object from SSE events.
- Tool use support is intentionally thin: it does not include a tool runner or automatic local bash execution.

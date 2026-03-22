# anthropic-sdk-zig

Minimal Zig wrapper for the Anthropic Claude Messages API.

This project follows the basic usage shape of `anthropic-sdk-python`, but only implements the smallest practical surface:

- synchronous client
- `POST /v1/messages`
- API key auth
- basic request/response structs
- parsed API error response

It intentionally does not implement streaming, batches, tools, beta APIs, retries, or higher-level abstractions.

## Requirements

- Zig `0.15.2`
- Anthropic API key in `ANTHROPIC_API_KEY`, or pass `api_key` explicitly

## Implemented API

The public module name is `anthropic_sdk_zig`.

Main entry points:

- `Client.init(allocator, options)`
- `client.messages().create(request)`
- `client.createMessage(request)`
- `MessageResponse.text(allocator)`

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

## Request shape

Currently supported request fields:

- `model`
- `max_tokens`
- `messages`
- `system`
- `temperature`
- `top_p`
- `top_k`
- `stop_sequences`

`messages[*].content` is currently plain text only.

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

The error path returns the parsed Claude error envelope plus HTTP status and `request-id`.

## Build

```sh
zig build
zig build test
```

## Notes

- This package is a library first. The bundled executable only prints a placeholder message.
- The current implementation is designed to stay close to the wire format instead of adding extra abstraction layers.

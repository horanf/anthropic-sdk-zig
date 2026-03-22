# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```sh
zig build              # build library + placeholder executable
zig build test         # run all tests
zig build run          # run the placeholder executable
zig build kimi-stream-chat  # run the Kimi streaming demo (requires env vars)
```

Requires Zig `0.15.2`. Set `ANTHROPIC_API_KEY` (or `KIMI_API_KEY`) before running the demo.

To run the Kimi demo:
```sh
cp .env-example .env   # fill in your key
set -a; . ./.env; set +a
zig build kimi-stream-chat
```

## Architecture

The public module name is `anthropic_sdk_zig`, rooted at `src/root.zig`.

```
src/root.zig          ← public API surface (re-exports from anthropic.zig)
src/anthropic.zig     ← aggregation hub (re-exports from sub-modules + test runner)
src/anthropic/
  types.zig           ← all request/response structs and enums
  client.zig          ← Client, Messages, MessageResponse, ErrorResponse, result unions
  stream.zig          ← MessageStream (SSE parser), ServerSentEvent
  constants.zig       ← default base URL, API version, user agent, max body size
  util.zig            ← resolveApiKey, resolveBaseUrl, readResponseBody, helpers
  tests.zig           ← integration tests with in-process HTTP TestServer
src/main.zig          ← placeholder CLI entry point (not the library surface)
examples/
  kimi_stream_chat.zig ← multi-turn streaming demo targeting Kimi Code API
```

## Key Patterns

**Result unions** — every network call returns a tagged union, never throws on API errors:
```zig
// CreateMessageResult = union(enum) { ok: MessageResponse, api_error: ErrorResponse }
switch (result) {
    .ok => |*msg| { ... },
    .api_error => |*err| { ... },
}
```

**Ownership & deinit** — every type that owns heap memory has `deinit()`. Call it on all results:
```zig
var result = try client.messages().create(...);
defer result.deinit();
```
`self.* = undefined` is used at the end of every `deinit` to catch use-after-free bugs.

**Custom JSON serialization** — `CreateMessageRequest` implements `writeJson` for custom field control (omits null optional fields, injects `stream: true` for streaming). Use `types.zig` as the reference when adding new request fields.

**Message content** — two ways to specify message content:
- `content: []const u8` — plain text shorthand
- `content_blocks: []const InputContentBlock` — mixed `text` + `tool_result` blocks

**Streaming** — `MessageStream` owns the `std.http.Client.Request` and keeps it alive across `nextEvent()` calls. The stream does not accumulate a final Message; it yields raw `ServerSentEvent` values. Use `event.textDelta(allocator)` for quick text extraction, or `event.json(T, allocator)` to parse a typed event.

**Tests** — `tests.zig` spins up a real in-process HTTP server (`TestServer`) in a goroutine for each test. There is no mocking. All four modes (`success`, `rate_limited`, `stream_success`, `tool_use_success`) are in `TestServerMode`. New tests should follow this pattern.

## Adding New Request Fields

1. Add the field to `CreateMessageRequest` in `types.zig`.
2. Handle it in `CreateMessageRequest.writeJson` — only emit the field when non-null/non-default.
3. Add a test case in `tests.zig` that verifies the field appears in `server.received_body`.

## Zig Version Notes

This project targets Zig `0.15.2` (nightly/dev). API surface used:
- `std.http.Client` with `sendBodyUnflushed` / `receiveHead`
- `std.Io.Writer.Allocating` for building JSON payloads
- `std.ArrayList(u8)` with explicit allocator parameter (`.empty` init, `appendSlice(allocator, ...)`)
- `std.json.Stringify.value` (not `stringify`)

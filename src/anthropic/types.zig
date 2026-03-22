const std = @import("std");
const constants = @import("constants.zig");

pub const ClientOptions = struct {
    api_key: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    anthropic_version: []const u8 = constants.default_anthropic_version,
    user_agent: []const u8 = constants.default_user_agent,
};

pub const Role = enum {
    user,
    assistant,

    pub fn jsonStringify(self: Role, jw: anytype) !void {
        try jw.write(@tagName(self));
    }
};

pub const TextInputBlock = struct {
    text: []const u8,
};

pub const ToolResultBlockParam = struct {
    tool_use_id: []const u8,
    content: []const u8,
    is_error: ?bool = null,
};

pub const InputContentBlock = union(enum) {
    text: TextInputBlock,
    tool_result: ToolResultBlockParam,

    pub fn jsonStringify(self: InputContentBlock, jw: anytype) !void {
        switch (self) {
            .text => |block| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("text");
                try jw.objectField("text");
                try jw.write(block.text);
                try jw.endObject();
            },
            .tool_result => |block| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("tool_result");
                try jw.objectField("tool_use_id");
                try jw.write(block.tool_use_id);
                try jw.objectField("content");
                try jw.write(block.content);
                if (block.is_error) |is_error| {
                    try jw.objectField("is_error");
                    try jw.write(is_error);
                }
                try jw.endObject();
            },
        }
    }
};

pub const MessageParam = struct {
    role: Role,
    content: ?[]const u8 = null,
    content_blocks: ?[]const InputContentBlock = null,

    pub fn jsonStringify(self: MessageParam, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("role");
        try jw.write(self.role);
        try jw.objectField("content");
        if (self.content_blocks) |content_blocks| {
            try jw.write(content_blocks);
        } else {
            try jw.write(self.content orelse "");
        }
        try jw.endObject();
    }
};

pub const BashToolDefinition = struct {
    name: []const u8 = "bash",
    type: []const u8 = "bash_20250124",
    strict: ?bool = null,

    pub fn jsonStringify(self: BashToolDefinition, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(self.type);
        try jw.objectField("name");
        try jw.write(self.name);
        if (self.strict) |strict| {
            try jw.objectField("strict");
            try jw.write(strict);
        }
        try jw.endObject();
    }
};

pub const ToolChoiceAny = struct {
    disable_parallel_tool_use: ?bool = null,
};

pub const ToolChoiceTool = struct {
    name: []const u8,
    disable_parallel_tool_use: ?bool = null,
};

pub const ToolChoice = union(enum) {
    any: ToolChoiceAny,
    tool: ToolChoiceTool,

    pub fn jsonStringify(self: ToolChoice, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .any => |choice| {
                try jw.objectField("type");
                try jw.write("any");
                if (choice.disable_parallel_tool_use) |disable_parallel_tool_use| {
                    try jw.objectField("disable_parallel_tool_use");
                    try jw.write(disable_parallel_tool_use);
                }
            },
            .tool => |choice| {
                try jw.objectField("type");
                try jw.write("tool");
                try jw.objectField("name");
                try jw.write(choice.name);
                if (choice.disable_parallel_tool_use) |disable_parallel_tool_use| {
                    try jw.objectField("disable_parallel_tool_use");
                    try jw.write(disable_parallel_tool_use);
                }
            },
        }
        try jw.endObject();
    }
};

pub const CreateMessageRequest = struct {
    model: []const u8,
    max_tokens: usize,
    messages: []const MessageParam,
    tools: ?[]const BashToolDefinition = null,
    tool_choice: ?ToolChoice = null,
    system: ?[]const u8 = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    top_k: ?u32 = null,
    stop_sequences: ?[]const []const u8 = null,

    pub fn jsonStringify(self: CreateMessageRequest, jw: anytype) !void {
        try self.writeJson(jw, null);
    }

    pub fn writeJson(self: CreateMessageRequest, jw: anytype, stream: ?bool) !void {
        try jw.beginObject();

        try jw.objectField("model");
        try jw.write(self.model);

        try jw.objectField("max_tokens");
        try jw.write(self.max_tokens);

        try jw.objectField("messages");
        try jw.write(self.messages);

        if (self.tools) |tools| {
            try jw.objectField("tools");
            try jw.write(tools);
        }

        if (self.tool_choice) |tool_choice| {
            try jw.objectField("tool_choice");
            try jw.write(tool_choice);
        }

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

        if (stream) |should_stream| {
            try jw.objectField("stream");
            try jw.write(should_stream);
        }

        try jw.endObject();
    }
};

pub const ContentBlock = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    input: ?std.json.Value = null,
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

pub const StreamPingEvent = struct {
    type: []const u8,
};

pub const StreamMessageStartEvent = struct {
    type: []const u8,
    message: Message,
};

pub const StreamContentBlock = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    input: ?std.json.Value = null,
};

pub const StreamContentBlockStartEvent = struct {
    type: []const u8,
    index: usize,
    content_block: StreamContentBlock,
};

pub const StreamContentDelta = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    partial_json: ?[]const u8 = null,
    thinking: ?[]const u8 = null,
    signature: ?[]const u8 = null,
};

pub const StreamContentBlockDeltaEvent = struct {
    type: []const u8,
    index: usize,
    delta: StreamContentDelta,
};

pub const StreamContentBlockStopEvent = struct {
    type: []const u8,
    index: usize,
};

pub const StreamMessageDelta = struct {
    stop_reason: ?[]const u8 = null,
    stop_sequence: ?[]const u8 = null,
};

pub const StreamUsage = struct {
    input_tokens: ?usize = null,
    output_tokens: ?usize = null,
    cache_creation_input_tokens: ?usize = null,
    cache_read_input_tokens: ?usize = null,
};

pub const StreamMessageDeltaEvent = struct {
    type: []const u8,
    delta: StreamMessageDelta,
    usage: ?StreamUsage = null,
};

pub const StreamMessageStopEvent = struct {
    type: []const u8,
};

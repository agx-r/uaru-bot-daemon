const std = @import("std");
const json = std.json;
const types = @import("types.zig");
const telegram = @import("telegram.zig");
const utils = @import("utils.zig");
const logger = @import("logger.zig");

fn callCoreBinary(allocator: std.mem.Allocator, message: types.TelegramUpdate.Message, log: *logger.Logger) !void {
    const pwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(pwd);
    const core_path = try std.fs.path.join(allocator, &[_][]const u8{ pwd, "kernel" });
    defer allocator.free(core_path);

    const from = message.from orelse {
        try log.warn("No 'from' field in message {}", .{message.message_id});
        return;
    };
    const chat = message.chat orelse {
        try log.warn("No 'chat' field in message {}", .{message.message_id});
        return;
    };
    const json_arg = try std.json.stringifyAlloc(allocator, .{
        .event = "messageSent",
        .message = .{
            .text = message.text orelse "",
            .messageId = message.message_id,
            .replyToMessage = null,
            .isImage = false,
            .isFile = false,
            .isSticker = false,
            .fromUser = .{
                .userId = from.id,
                .firstName = from.first_name,
                .username = from.username orelse "",
            },
        },
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(json_arg);

    try log.debug("Executing core binary with JSON: {s}", .{json_arg});
    var child = std.process.Child.init(&[_][]const u8{ core_path, json_arg }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout = std.ArrayList(u8).init(allocator);
    defer stdout.deinit();
    var stderr = std.ArrayList(u8).init(allocator);
    defer stderr.deinit();

    try child.stdout.?.reader().readAllArrayList(&stdout, std.math.maxInt(usize));
    try child.stderr.?.reader().readAllArrayList(&stderr, std.math.maxInt(usize));

    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        try log.err("Core binary failed: {s}", .{stderr.items});
        return error.CoreBinaryFailed;
    }

    if (stdout.items.len > 0) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        const parsed = json.parseFromSlice(types.CoreResponse, arena_allocator, stdout.items, .{}) catch |err| {
            if (err == error.UnexpectedToken) {
                try log.warn("Unexpected JSON token in core response, ignoring", .{});
                return;
            }
            try log.err("Failed to parse core response: {s}", .{@errorName(err)});
            return err;
        };
        defer parsed.deinit();

        // Handle log from core response
        if (parsed.value.log) |core_log| {
            const level = if (std.mem.eql(u8, core_log.level, "info"))
                logger.LogLevel.INFO
            else if (std.mem.eql(u8, core_log.level, "debug"))
                logger.LogLevel.DEBUG
            else if (std.mem.eql(u8, core_log.level, "error"))
                logger.LogLevel.ERROR
            else
                logger.LogLevel.WARN;

            try log.log(level, "Core: {s}", .{core_log.msg});
        }

        // Handle actions
        if (parsed.value.actions) |actions| {
            if (actions.sendMessage) |send_msg| {
                try telegram.sendMessage(allocator, try utils.readBotToken(allocator, log), chat.id, send_msg.text, send_msg.replyToId, log);
            }
        }
    }
}

fn setupMessageHandler(allocator: std.mem.Allocator, bot_token: []const u8, polling_offset: i64, log: *logger.Logger) !void {
    var polling_offset_mutable: i64 = polling_offset;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    try log.info("Starting message handler with initial offset {}", .{polling_offset});
    while (true) {
        const polling_updates = try telegram.getUpdates(arena_allocator, bot_token, polling_offset_mutable, log);
        defer arena_allocator.free(polling_updates);

        for (polling_updates) |polling_update| {
            try messageHandler(arena_allocator, polling_update, log);

            if (polling_update.update_id >= polling_offset_mutable) {
                polling_offset_mutable = polling_update.update_id + 1;
                try log.debug("Updated polling offset to {}", .{polling_offset_mutable});
            }
        }
        std.time.sleep(500 * std.time.ns_per_ms);
    }
}

fn messageHandler(allocator: std.mem.Allocator, polling_update: types.TelegramUpdate, log: *logger.Logger) !void {
    if (polling_update.message) |msg| {
        if (msg.from) |_| {
            try log.info("Processing message {} from chat {}", .{msg.message_id, msg.chat.?.id});
            try callCoreBinary(allocator, msg, log);
        } else {
            try log.warn("Message {} has no sender information", .{msg.message_id});
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var log = try logger.Logger.init(allocator, .INFO, "bot.log");
    defer log.deinit();

    try log.info("Starting Telegram bot", .{});
    const bot_token = utils.readBotToken(allocator, &log) catch |err| {
        utils.handleTokenIssue(err, &log);
        return;
    };
    defer allocator.free(bot_token);

    const polling_offset = try telegram.getPollingOffset(allocator, bot_token, &log);
    try setupMessageHandler(allocator, bot_token, polling_offset, &log);
}

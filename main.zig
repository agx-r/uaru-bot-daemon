const std = @import("std");
const json = std.json;
const types = @import("types.zig");
const telegram = @import("telegram.zig");
const utils = @import("utils.zig");

fn callCoreBinary(allocator: std.mem.Allocator, message: types.TelegramUpdate.Message) !void {
    const pwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(pwd);
    const core_path = try std.fs.path.join(allocator, &[_][]const u8{ pwd, "kernel" });
    defer allocator.free(core_path);

    const from = message.from orelse return;
    const chat = message.chat orelse return;
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
        const stderr_writer = std.io.getStdErr().writer();
        try stderr_writer.print("\x1b[31mcore binary failed: {s}\x1b[0m\n", .{stderr.items});
        return error.CoreBinaryFailed;
    }

    if (stdout.items.len > 0) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        const parsed = json.parseFromSlice(types.CoreResponse, arena_allocator, stdout.items, .{}) catch |err| {
            if (err == error.UnexpectedToken) {
                return; // Treat UnexpectedToken as non-error (feature)
            }
            return err;
        };
        defer parsed.deinit();

        // Print log with color based on level
        if (parsed.value.log) |log| {
            const stderr_writer = std.io.getStdErr().writer();
            const color = if (std.mem.eql(u8, log.level, "info"))
                "\x1b[32m" // Green for info
            else if (std.mem.eql(u8, log.level, "debug"))
                "\x1b[34m" // Blue for debug
            else if (std.mem.eql(u8, log.level, "error"))
                "\x1b[31m" // Red for error
            else
                "\x1b[33m"; // Yellow for others
            try stderr_writer.print("{s}{s}\x1b[0m\n", .{color, log.msg});
        }

        // Handle actions
        if (parsed.value.actions) |actions| {
            if (actions.sendMessage) |send_msg| {
                try telegram.sendMessage(allocator, try utils.readBotToken(allocator), chat.id, send_msg.text, send_msg.replyToId);
            }
        }
    }
}

fn setupMessageHandler(allocator: std.mem.Allocator, bot_token: []const u8, polling_offset: i64) !void {
    var polling_offset_mutable: i64 = polling_offset;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    while (true) {
        const polling_updates = try telegram.getUpdates(arena_allocator, bot_token, polling_offset_mutable);
        defer arena_allocator.free(polling_updates);

        for (polling_updates) |polling_update| {
            try messageHandler(arena_allocator, polling_update);

            if (polling_update.update_id >= polling_offset_mutable) {
                polling_offset_mutable = polling_update.update_id + 1;
            }
        }
        std.time.sleep(500 * std.time.ns_per_ms);
    }
}

fn messageHandler(allocator: std.mem.Allocator, polling_update: types.TelegramUpdate) !void {
    if (polling_update.message) |msg| {
        if (msg.from) |_| {
            try callCoreBinary(allocator, msg);
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const bot_token = utils.readBotToken(allocator) catch |err| {
        utils.handleTokenError(err);
        return;
    };
    defer allocator.free(bot_token);

    const polling_offset = try telegram.getPollingOffset(allocator, bot_token);

    try setupMessageHandler(allocator, bot_token, polling_offset);
}

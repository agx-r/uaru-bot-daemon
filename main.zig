const std = @import("std");
const json = std.json;

const telegram_api_url = "https://api.telegram.org/bot";

pub const TelegramUpdate = struct {
    update_id: i64,
    message: ?Message = null,

    pub const Message = struct {
        message_id: i64,
        text: ?[]const u8 = null,
        from: ?User = null,
        chat: ?Chat = null,
        date: i64,
        entities: ?[]MessageEntity = null,

        pub const User = struct {
            id: i64,
            is_bot: bool,
            first_name: []const u8,
            username: ?[]const u8 = null,
            language_code: ?[]const u8 = null,
        };

        pub const Chat = struct {
            id: i64,
            first_name: ?[]const u8 = null,
            username: ?[]const u8 = null,
            type: []const u8,
        };

        pub const MessageEntity = struct {
            offset: i64,
            length: i64,
            type: []const u8,
        };
    };
};

pub const CoreResponse = struct {
    status: []const u8,
    log: ?Log = null,
    actions: ?Actions = null,

    pub const Log = struct {
        msg: []const u8,
        level: []const u8,
    };

    pub const Actions = struct {
        sendMessage: ?SendMessage = null,
        unmuteUser: ?[]const u8 = null,
        pinMessage: ?[]const u8 = null,
        muteUser: ?[]const u8 = null,
        deleteMessage: ?[]const u8 = null,
        banUser: ?[]const u8 = null,

        pub const SendMessage = struct {
            text: []const u8,
            replyToId: ?i64 = null,
        };
    };
};

pub fn parseUpdates(allocator: std.mem.Allocator, json_str: []const u8) ![]TelegramUpdate {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const parsed = try json.parseFromSlice(json.Value, arena_allocator, json_str, .{});
    defer parsed.deinit();

    const results = parsed.value.object.get("result") orelse return error.InvalidJson;
    const result_array = results.array;

    var updates = try std.ArrayList(TelegramUpdate).initCapacity(allocator, result_array.items.len);
    defer updates.deinit();

    for (result_array.items) |result| {
        try updates.append(try parseSingleUpdate(arena_allocator, result));
    }

    return updates.toOwnedSlice();
}

fn parseSingleUpdate(allocator: std.mem.Allocator, update_value: json.Value) !TelegramUpdate {
    const obj = update_value.object;
    const update_id_val = obj.get("update_id") orelse return error.InvalidJsonUpdateId;
    if (update_id_val != .integer) return error.InvalidJsonUpdateId;

    var update = TelegramUpdate{
        .update_id = update_id_val.integer,
    };

    if (obj.get("message")) |message_val| {
        const msg_obj = message_val.object;
        const message_id_val = msg_obj.get("message_id") orelse return error.InvalidJsonMessageId;
        const date_val = msg_obj.get("date") orelse return error.InvalidJsonDate;
        if (message_id_val != .integer or date_val != .integer) return error.InvalidJsonType;

        var message = TelegramUpdate.Message{
            .message_id = message_id_val.integer,
            .date = date_val.integer,
            .text = if (msg_obj.get("text")) |t| t.string else null,
        };

        if (msg_obj.get("from")) |from_val| {
            const from_obj = from_val.object;
            const id_val = from_obj.get("id") orelse return error.InvalidJsonUserId;
            const is_bot_val = from_obj.get("is_bot") orelse return error.InvalidJsonIsBot;
            const first_name_val = from_obj.get("first_name") orelse return error.InvalidJsonFirstName;
            if (id_val != .integer or is_bot_val != .bool or first_name_val != .string) return error.InvalidJsonType;

            message.from = .{
                .id = id_val.integer,
                .is_bot = is_bot_val.bool,
                .first_name = first_name_val.string,
                .username = if (from_obj.get("username")) |u| u.string else null,
                .language_code = if (from_obj.get("language_code")) |l| l.string else null,
            };
        }

        if (msg_obj.get("chat")) |chat_val| {
            const chat_obj = chat_val.object;
            const id_val = chat_obj.get("id") orelse return error.InvalidJsonChatId;
            const type_val = chat_obj.get("type") orelse return error.InvalidJsonChatType;
        if (id_val != .integer or type_val != .string) return error.InvalidJsonType;

            message.chat = .{
                .id = id_val.integer,
                .first_name = if (chat_obj.get("first_name")) |f| f.string else null,
                .username = if (chat_obj.get("username")) |u| u.string else null,
                .type = type_val.string,
            };
        }

        if (msg_obj.get("entities")) |entities_val| {
            const entities_arr = entities_val.array;
            var entities = try std.ArrayList(TelegramUpdate.Message.MessageEntity).initCapacity(allocator, entities_arr.items.len);

            for (entities_arr.items) |entity_val| {
                const entity_obj = entity_val.object;
                const offset_val = entity_obj.get("offset") orelse return error.InvalidJsonOffset;
                const length_val = entity_obj.get("length") orelse return error.InvalidJsonLength;
                const type_val = entity_obj.get("type") orelse return error.InvalidJsonEntityType;
                if (offset_val != .integer or length_val != .integer or type_val != .string) return error.InvalidJsonType;

                entities.appendAssumeCapacity(.{
                    .offset = offset_val.integer,
                    .length = length_val.integer,
                    .type = type_val.string,
                });
            }

            message.entities = try entities.toOwnedSlice();
        }

        update.message = message;
    }

    return update;
}

pub fn readFileAsString(allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

fn readExactBytes(file_path: []const u8, buffer: []u8) !void {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const bytes_read = try file.readAll(buffer);
    if (bytes_read != buffer.len) {
        return error.UnexpectedFileSize;
    }
}

fn curlRequest(allocator: std.mem.Allocator, request: []const u8) ![]const u8 {
    const curl_args = [_][]const u8{
        "curl",
        "-s",
        request
    };

    var child = std.process.Child.init(&curl_args, allocator);
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
        return error.CurlFailed;
    }

    return stdout.toOwnedSlice();
}

fn verifyFileSize(file_path: []const u8, expected_size: usize) !void {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    
    const actual_size = (try file.stat()).size;
    if (actual_size != expected_size) {
        return error.InvalidFileSize;
    }
}

fn getUpdates(allocator: std.mem.Allocator, bot_token: []const u8, offset: i64) ![]TelegramUpdate {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const full_url = try std.fmt.allocPrint(arena_allocator, "{s}{s}/getUpdates?offset={}", .{telegram_api_url, bot_token, offset});
    const answer_json = try curlRequest(arena_allocator, full_url);
    
    return try parseUpdates(allocator, answer_json);
}

fn getPollingOffset(allocator: std.mem.Allocator, bot_token: []const u8) !i64 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const full_url = try std.fmt.allocPrint(arena_allocator, "{s}{s}/getUpdates?offset=0", .{telegram_api_url, bot_token});
    const answer_json = try curlRequest(arena_allocator, full_url);
    
    const updates = try parseUpdates(allocator, answer_json);
    defer allocator.free(updates);

    if (updates.len == 0) {
        return 0;
    }

    return updates[updates.len - 1].update_id;
}

fn readBotToken(allocator: std.mem.Allocator) ![]const u8 {
    const file_path = "token.txt";
    try verifyFileSize(file_path, 45);
    return try readFileAsString(allocator, file_path);
}

fn handleTokenError(err: anyerror) void {
    const stderr = std.io.getStdErr().writer();
    switch (err) {
        error.FileNotFound => stderr.print("\x1b[31mtoken.txt not found\x1b[0m\n", .{}) catch {},
        error.AccessDenied => stderr.print("\x1b[31mtoken.txt access denied\x1b[0m\n", .{}) catch {},
        error.UnexpectedFileSize, error.InvalidFileSize => 
            stderr.print("\x1b[31mtoken.txt invalid file size\x1b[0m\n", .{}) catch {},
        else => stderr.print("\x1b[31mError: {s}\x1b[0m\n", .{@errorName(err)}) catch {},
    }
}

fn sendMessage(allocator: std.mem.Allocator, bot_token: []const u8, chat_id: i64, text: []const u8, reply_to_id: ?i64) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const url = if (reply_to_id) |reply_id|
        try std.fmt.allocPrint(arena_allocator, "{s}{s}/sendMessage?chat_id={}&text={s}&reply_to_message_id={}", .{telegram_api_url, bot_token, chat_id, text, reply_id})
    else
        try std.fmt.allocPrint(arena_allocator, "{s}{s}/sendMessage?chat_id={}&text={s}", .{telegram_api_url, bot_token, chat_id, text});

    const response = try curlRequest(arena_allocator, url);
    defer arena_allocator.free(response);

    const parsed = try json.parseFromSlice(json.Value, arena_allocator, response, .{});
    defer parsed.deinit();

    const ok = parsed.value.object.get("ok") orelse return error.InvalidTelegramResponse;
    if (!ok.bool) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("\x1b[31mTelegram API error: {s}\x1b[0m\n", .{response});
        return error.TelegramApiError;
    }
}

fn callCoreBinary(allocator: std.mem.Allocator, message: TelegramUpdate.Message) !void {
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

        const parsed = json.parseFromSlice(CoreResponse, arena_allocator, stdout.items, .{}) catch |err| {
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
                try sendMessage(allocator, try readBotToken(allocator), chat.id, send_msg.text, send_msg.replyToId);
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
        const polling_updates = try getUpdates(arena_allocator, bot_token, polling_offset_mutable);
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

fn messageHandler(allocator: std.mem.Allocator, polling_update: TelegramUpdate) !void {
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

    const bot_token = readBotToken(allocator) catch |err| {
        handleTokenError(err);
        return;
    };
    defer allocator.free(bot_token);

    const polling_offset = try getPollingOffset(allocator, bot_token);

    try setupMessageHandler(allocator, bot_token, polling_offset);
}

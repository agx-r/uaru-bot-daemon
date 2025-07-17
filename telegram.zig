const std = @import("std");
const json = std.json;
const types = @import("types.zig");
const logger = @import("logger.zig");

const telegram_api_url = "https://api.telegram.org/bot";

pub fn parseUpdates(allocator: std.mem.Allocator, json_str: []const u8, log: *logger.Logger) ![]types.TelegramUpdate {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const parsed = try json.parseFromSlice(json.Value, arena_allocator, json_str, .{});
    defer parsed.deinit();

    const results = parsed.value.object.get("result") orelse {
        try log.err("Invalid JSON: No 'result' field found", .{});
        return error.InvalidJson;
    };
    const result_array = results.array;

    var updates = try std.ArrayList(types.TelegramUpdate).initCapacity(allocator, result_array.items.len);
    defer updates.deinit();

    for (result_array.items) |result| {
        try updates.append(try parseSingleUpdate(arena_allocator, result, log));
    }

    return updates.toOwnedSlice();
}

fn parseSingleUpdate(allocator: std.mem.Allocator, update_value: json.Value, log: *logger.Logger) !types.TelegramUpdate {
    const obj = update_value.object;
    const update_id_val = obj.get("update_id") orelse {
        try log.err("Invalid JSON: Missing update_id", .{});
        return error.InvalidJsonUpdateId;
    };
    if (update_id_val != .integer) {
        try log.err("Invalid JSON: update_id is not an integer", .{});
        return error.InvalidJsonUpdateId;
    }

    var update = types.TelegramUpdate{
        .update_id = update_id_val.integer,
    };

    if (obj.get("message")) |message_val| {
        const msg_obj = message_val.object;
        const message_id_val = msg_obj.get("message_id") orelse {
            try log.err("Invalid JSON: Missing message_id", .{});
            return error.InvalidJsonMessageId;
        };
        const date_val = msg_obj.get("date") orelse {
            try log.err("Invalid JSON: Missing date", .{});
            return error.InvalidJsonDate;
        };
        if (message_id_val != .integer or date_val != .integer) {
            try log.err("Invalid JSON: Invalid type for message_id or date", .{});
            return error.InvalidJsonType;
        }

        var message = types.TelegramUpdate.Message{
            .message_id = message_id_val.integer,
            .date = date_val.integer,
            .text = if (msg_obj.get("text")) |t| t.string else null,
        };

        if (msg_obj.get("from")) |from_val| {
            const from_obj = from_val.object;
            const id_val = from_obj.get("id") orelse {
                try log.err("Invalid JSON: Missing user id", .{});
                return error.InvalidJsonUserId;
            };
            const is_bot_val = from_obj.get("is_bot") orelse {
                try log.err("Invalid JSON: Missing is_bot field", .{});
                return error.InvalidJsonIsBot;
            };
            const first_name_val = from_obj.get("first_name") orelse {
                try log.err("Invalid JSON: Missing first_name", .{});
                return error.InvalidJsonFirstName;
            };
            if (id_val != .integer or is_bot_val != .bool or first_name_val != .string) {
                try log.err("Invalid JSON: Invalid type for user fields", .{});
                return error.InvalidJsonType;
            }

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
            const id_val = chat_obj.get("id") orelse {
                try log.err("Invalid JSON: Missing chat id", .{});
                return error.InvalidJsonChatId;
            };
            const type_val = chat_obj.get("type") orelse {
                try log.err("Invalid JSON: Missing chat type", .{});
                return error.InvalidJsonChatType;
            };
            if (id_val != .integer or type_val != .string) {
                try log.err("Invalid JSON: Invalid type for chat fields", .{});
                return error.InvalidJsonType;
            }

            message.chat = .{
                .id = id_val.integer,
                .first_name = if (chat_obj.get("first_name")) |f| f.string else null,
                .username = if (chat_obj.get("username")) |u| u.string else null,
                .type = type_val.string,
            };
        }

        if (msg_obj.get("entities")) |entities_val| {
            const entities_arr = entities_val.array;
            var entities = try std.ArrayList(types.TelegramUpdate.Message.MessageEntity).initCapacity(allocator, entities_arr.items.len);

            for (entities_arr.items) |entity_val| {
                const entity_obj = entity_val.object;
                const offset_val = entity_obj.get("offset") orelse {
                    try log.err("Invalid JSON: Missing entity offset", .{});
                    return error.InvalidJsonOffset;
                };
                const length_val = entity_obj.get("length") orelse {
                    try log.err("Invalid JSON: Missing entity length", .{});
                    return error.InvalidJsonLength;
                };
                const type_val = entity_obj.get("type") orelse {
                    try log.err("Invalid JSON: Missing entity type", .{});
                    return error.InvalidJsonEntityType;
                };
                if (offset_val != .integer or length_val != .integer or type_val != .string) {
                    try log.err("Invalid JSON: Invalid type for entity fields", .{});
                    return error.InvalidJsonType;
                }

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

pub fn getUpdates(allocator: std.mem.Allocator, bot_token: []const u8, offset: i64, log: *logger.Logger) ![]types.TelegramUpdate {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const full_url = try std.fmt.allocPrint(arena_allocator, "{s}{s}/getUpdates?offset={}", .{telegram_api_url, bot_token, offset});
    try log.debug("Fetching updates from URL: {s}", .{full_url});
    const answer_json = try curlRequest(arena_allocator, full_url, log);
    
    return try parseUpdates(allocator, answer_json, log);
}

pub fn getPollingOffset(allocator: std.mem.Allocator, bot_token: []const u8, log: *logger.Logger) !i64 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const full_url = try std.fmt.allocPrint(arena_allocator, "{s}{s}/getUpdates?offset=0", .{telegram_api_url, bot_token});
    try log.debug("Getting polling offset from URL: {s}", .{full_url});
    const answer_json = try curlRequest(arena_allocator, full_url, log);
    
    const updates = try parseUpdates(allocator, answer_json, log);
    defer allocator.free(updates);

    if (updates.len == 0) {
        try log.info("No updates found, starting with offset 0", .{});
        return 0;
    }

    try log.info("Found {} updates, using offset {}", .{updates.len, updates[updates.len - 1].update_id});
    return updates[updates.len - 1].update_id;
}

pub fn sendMessage(allocator: std.mem.Allocator, bot_token: []const u8, chat_id: i64, text: []const u8, reply_to_id: ?i64, log: *logger.Logger) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const url = if (reply_to_id) |reply_id|
        try std.fmt.allocPrint(arena_allocator, "{s}{s}/sendMessage?chat_id={}&text={s}&reply_to_message_id={}", .{telegram_api_url, bot_token, chat_id, text, reply_id})
    else
        try std.fmt.allocPrint(arena_allocator, "{s}{s}/sendMessage?chat_id={}&text={s}", .{telegram_api_url, bot_token, chat_id, text});

    try log.debug("Sending message to chat {}: {s}", .{chat_id, text});
    const response = try curlRequest(arena_allocator, url, log);
    defer arena_allocator.free(response);

    const parsed = try json.parseFromSlice(json.Value, arena_allocator, response, .{});
    defer parsed.deinit();

    const ok = parsed.value.object.get("ok") orelse {
        try log.err("Invalid Telegram response: missing 'ok' field", .{});
        return error.InvalidTelegramResponse;
    };
    if (!ok.bool) {
        try log.err("Telegram API failure: {s}", .{response});
        return error.TelegramApiError;
    }

    try log.info("Message sent successfully to chat {}", .{chat_id});
}
fn curlRequest(allocator: std.mem.Allocator, request: []const u8, log: *logger.Logger) ![]const u8 {
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
        try log.err("Curl request failed: {s}", .{stderr.items});
        return error.CurlFailed;
    }

    try log.debug("Curl request successful, response length: {}", .{stdout.items.len});
    return stdout.toOwnedSlice();
}

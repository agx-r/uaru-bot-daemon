const std = @import("std");
const json = std.json;
const types = @import("types.zig");

const telegram_api_url = "https://api.telegram.org/bot";

pub fn parseUpdates(allocator: std.mem.Allocator, json_str: []const u8) ![]types.TelegramUpdate {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const parsed = try json.parseFromSlice(json.Value, arena_allocator, json_str, .{});
    defer parsed.deinit();

    const results = parsed.value.object.get("result") orelse return error.InvalidJson;
    const result_array = results.array;

    var updates = try std.ArrayList(types.TelegramUpdate).initCapacity(allocator, result_array.items.len);
    defer updates.deinit();

    for (result_array.items) |result| {
        try updates.append(try parseSingleUpdate(arena_allocator, result));
    }

    return updates.toOwnedSlice();
}

fn parseSingleUpdate(allocator: std.mem.Allocator, update_value: json.Value) !types.TelegramUpdate {
    const obj = update_value.object;
    const update_id_val = obj.get("update_id") orelse return error.InvalidJsonUpdateId;
    if (update_id_val != .integer) return error.InvalidJsonUpdateId;

    var update = types.TelegramUpdate{
        .update_id = update_id_val.integer,
    };

    if (obj.get("message")) |message_val| {
        const msg_obj = message_val.object;
        const message_id_val = msg_obj.get("message_id") orelse return error.InvalidJsonMessageId;
        const date_val = msg_obj.get("date") orelse return error.InvalidJsonDate;
        if (message_id_val != .integer or date_val != .integer) return error.InvalidJsonType;

        var message = types.TelegramUpdate.Message{
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
            var entities = try std.ArrayList(types.TelegramUpdate.Message.MessageEntity).initCapacity(allocator, entities_arr.items.len);

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

pub fn getUpdates(allocator: std.mem.Allocator, bot_token: []const u8, offset: i64) ![]types.TelegramUpdate {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const full_url = try std.fmt.allocPrint(arena_allocator, "{s}{s}/getUpdates?offset={}", .{telegram_api_url, bot_token, offset});
    const answer_json = try curlRequest(arena_allocator, full_url);
    
    return try parseUpdates(allocator, answer_json);
}

pub fn getPollingOffset(allocator: std.mem.Allocator, bot_token: []const u8) !i64 {
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

pub fn sendMessage(allocator: std.mem.Allocator, bot_token: []const u8, chat_id: i64, text: []const u8, reply_to_id: ?i64) !void {
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

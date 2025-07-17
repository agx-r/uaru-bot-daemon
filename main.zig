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

pub fn parseUpdates(allocator: std.mem.Allocator, json_str: []const u8) ![]TelegramUpdate {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try json.parseFromSlice(json.Value, arena.allocator(), json_str, .{});
    defer parsed.deinit();

    const results = parsed.value.object.get("result").?.array;
    var updates = try std.ArrayList(TelegramUpdate).initCapacity(allocator, results.items.len);
    errdefer updates.deinit();

    for (results.items) |result| {
        try updates.append(try parseSingleUpdate(result));
    }

    return updates.toOwnedSlice();
}


fn parseSingleUpdate(update_value: json.Value) !TelegramUpdate {
    const obj = update_value.object;
    var update = TelegramUpdate{
        .update_id = obj.get("update_id").?.integer,
    };

    if (obj.get("message")) |message_val| {
        const msg_obj = message_val.object;
        var message = TelegramUpdate.Message{
            .message_id = msg_obj.get("message_id").?.integer,
            .date = msg_obj.get("date").?.integer,
            .text = if (msg_obj.get("text")) |t| t.string else null,
        };

        if (msg_obj.get("from")) |from_val| {
            const from_obj = from_val.object;
            message.from = .{
                .id = from_obj.get("id").?.integer,
                .is_bot = from_obj.get("is_bot").?.bool,
                .first_name = from_obj.get("first_name").?.string,
                .username = if (from_obj.get("username")) |u| u.string else null,
                .language_code = if (from_obj.get("language_code")) |l| l.string else null,
            };
        }

        if (msg_obj.get("chat")) |chat_val| {
            const chat_obj = chat_val.object;
            message.chat = .{
                .id = chat_obj.get("id").?.integer,
                .first_name = if (chat_obj.get("first_name")) |f| f.string else null,
                .username = if (chat_obj.get("username")) |u| u.string else null,
                .type = chat_obj.get("type").?.string,
            };
        }

        if (msg_obj.get("entities")) |entities_val| {
            const entities_arr = entities_val.array;
            var entities = try std.ArrayList(TelegramUpdate.Message.MessageEntity).initCapacity(std.heap.page_allocator, entities_arr.items.len);
            defer entities.deinit();

            for (entities_arr.items) |entity_val| {
                const entity_obj = entity_val.object;
                entities.appendAssumeCapacity(.{
                    .offset = entity_obj.get("offset").?.integer,
                    .length = entity_obj.get("length").?.integer,
                    .type = entity_obj.get("type").?.string,
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

    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    
    return content;
}

fn readExactBytes(file_path: []const u8, buffer: []u8) !void {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const bytes_read = try file.readAll(buffer);
    if (bytes_read != buffer.len) {
        return error.UnexpectedFileSize;
    }
}

fn curlRequest(request: []const u8) ![]const u8 {
    const allocator = std.heap.page_allocator;
    
    const curl_args = [_][]const u8{
        "curl",
        "-s",
        request
    };

    var child = std.process.Child.init(&curl_args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();

    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    errdefer allocator.free(stdout);

    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(stderr);

    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        std.debug.print("curl failed ({}): {s}\n", .{term, stderr});
        return error.CurlFailed;
    }

    // Удаляем завершающие нулевые байты и whitespace
    const trimmed = std.mem.trim(u8, stdout, &std.ascii.whitespace ++ [_]u8{0});
    if (trimmed.len != stdout.len) {
        const cleaned = try allocator.dupe(u8, trimmed);
        allocator.free(stdout);
        return cleaned;
    }

    return stdout;
}

fn verifyFileSize(file_path: []const u8, expected_size: usize) !void {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    
    const actual_size = (try file.stat()).size;
    if (actual_size != expected_size) {
        return error.InvalidFileSize;
    }
}

fn getPollingOffset(token: []const u8) !i64 {
    const full_url = try std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}/getUpdates?offset=0", .{telegram_api_url, token});
    defer std.heap.page_allocator.free(full_url);
    const answer_json = try curlRequest(full_url);
    std.debug.print("Polling offset request := {s}\n", .{full_url});
    std.debug.print("Polling offset response := {s}\n", .{answer_json});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const updates = try parseUpdates(allocator, answer_json);
    defer allocator.free(updates);

    if (updates.len == 0) {
        return 0;
    }

    return updates[updates.len - 1].update_id;
}

fn readBotToken() ![45]u8 {
    const file_path = "token.txt";
    try verifyFileSize(file_path, 45);

    var buffer: [45]u8 = undefined;
    try readExactBytes(file_path, &buffer);
    return buffer;
}
fn handleTokenError(err: anyerror) void {
    switch (err) {
        error.FileNotFound => std.debug.print("token.txt not found\n", .{}),
        error.AccessDenied => std.debug.print("token.txt access denied\n", .{}),
        error.UnexpectedFileSize, error.InvalidFileSize => 
            std.debug.print("token.txt invalid file size\n", .{}),
        else => std.debug.print("Error: {s}\n", .{@errorName(err)}),
    }
}

pub fn main() !void {
    std.debug.print("{s}\n", .{"Started"});

    const bot_token = readBotToken() catch |err| {
        handleTokenError(err);
        return;
    };

    const polling_offset: i64 = try getPollingOffset(&bot_token);
    std.debug.print("Polling offset := {}\n", .{polling_offset});

    // while (true) {
        
    // }
}

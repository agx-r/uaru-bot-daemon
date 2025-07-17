const std = @import("std");
const json = std.json;

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

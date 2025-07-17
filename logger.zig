const std = @import("std");

pub const LogLevel = enum {
    DEBUG,
    INFO,
    WARN,
    ERROR,

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .DEBUG => "DEBUG",
            .INFO => "INFO",
            .WARN => "WARN",
            .ERROR => "ERROR",
        };
    }
};

pub const Logger = struct {
    allocator: std.mem.Allocator,
    min_level: LogLevel,
    file: ?std.fs.File,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, min_level: LogLevel, log_file_path: ?[]const u8) !Logger {
        var file: ?std.fs.File = null;
        if (log_file_path) |path| {
            file = try std.fs.cwd().createFile(path, .{ .truncate = false });
        }

        return Logger{
            .allocator = allocator,
            .min_level = min_level,
            .file = file,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Logger) void {
        if (self.file) |f| {
            f.close();
        }
    }

    pub fn log(self: *Logger, level: LogLevel, comptime fmt: []const u8, args: anytype) !void {
        if (@intFromEnum(level) < @intFromEnum(self.min_level)) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        const timestamp = std.time.milliTimestamp();
        const time_str = try std.fmt.allocPrint(self.allocator, "{d}", .{timestamp});
        defer self.allocator.free(time_str);

        const msg_content = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(msg_content);

        const level_background = switch (level) {
            .INFO => "\x1b[30;42m",  // black on green
            .DEBUG => "\x1b[30;44m", // black on blue
            .WARN => "\x1b[30;43m",  // black on yellow
            .ERROR => "\x1b[30;41m", // black on red
        };

        const bracket_color = switch (level) {
            .INFO => "\x1b[32m",
            .DEBUG => "\x1b[34m",
            .WARN => "\x1b[33m",
            .ERROR => "\x1b[31m",
        };

        const time_color = "\x1b[90m"; // dim grey
        const msg_color = "\x1b[37m";  // white

        const level_str = level.toString();

        const colored_level = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s} {s}\x1b[0m{s}",
            .{ bracket_color, level_background, level_str, bracket_color }
        );
        defer self.allocator.free(colored_level);

        const line1 = try std.fmt.allocPrint(
            self.allocator,
            "{s}[{s}{s}{s}] {s}\n",
            .{ time_color, bracket_color, time_str, time_color, colored_level }
        );
        defer self.allocator.free(line1);

        const line2 = try std.fmt.allocPrint(
            self.allocator,
            "{s}╰ {s}{s}\x1b[0m\n\n",
            .{ bracket_color, msg_color, msg_content }
        );
        defer self.allocator.free(line2);

        const stderr = std.io.getStdErr().writer();
        try stderr.print("{s}{s}", .{ line1, line2 });

        if (self.file) |f| {
            const plain_msg = try std.fmt.allocPrint(
                self.allocator,
                "[{s}] [{s}] {s}\n",
                .{ time_str, level_str, msg_content }
            );
            defer self.allocator.free(plain_msg);
            try f.writeAll(plain_msg);
        }
    }

    pub fn debug(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
        try self.log(.DEBUG, fmt, args);
    }

    pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
        try self.log(.INFO, fmt, args);
    }

    pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
        try self.log(.WARN, fmt, args);
    }

    pub fn err(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
        try self.log(.ERROR, fmt, args);
    }
};

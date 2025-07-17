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

        const msg = try std.fmt.allocPrint(self.allocator, "[{s}] [{s}] {s}\n", .{ time_str, level.toString(), try std.fmt.allocPrint(self.allocator, fmt, args) });
        defer self.allocator.free(msg);

        // Write to console
        const stderr = std.io.getStdErr().writer();
        const color = switch (level) {
            .INFO => "\x1b[32m", // Green
            .DEBUG => "\x1b[34m", // Blue
            .ERROR => "\x1b[31m", // Red
            .WARN => "\x1b[33m", // Yellow
        };
        try stderr.print("{s}{s}\x1b[0m", .{color, msg});

        // Write to file if configured
        if (self.file) |f| {
            try f.writeAll(msg);
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

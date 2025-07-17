const std = @import("std");
const logger = @import("logger.zig");

pub fn readFileAsString(allocator: std.mem.Allocator, file_path: []const u8, log: *logger.Logger) ![]u8 {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    try log.debug("Reading file: {s}", .{file_path});
    return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

pub fn readExactBytes(file_path: []const u8, buffer: []u8, log: *logger.Logger) !void {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    try log.debug("Reading exact bytes from file: {s}", .{file_path});
    const bytes_read = try file.readAll(buffer);
    if (bytes_read != buffer.len) {
        try log.err("Unexpected file size for {s}: expected {}, got {}", .{file_path, buffer.len, bytes_read});
        return error.UnexpectedFileSize;
    }
}

pub fn verifyFileSize(file_path: []const u8, expected_size: usize, log: *logger.Logger) !void {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    
    const actual_size = (try file.stat()).size;
    if (actual_size != expected_size) {
        try log.err("Invalid file size for {s}: expected {}, got {}", .{file_path, expected_size, actual_size});
        return error.InvalidFileSize;
    }
}

pub fn readBotToken(allocator: std.mem.Allocator, log: *logger.Logger) ![]const u8 {
    const file_path = "token.txt";
    try verifyFileSize(file_path, 45, log);
    return try readFileAsString(allocator, file_path, log);
}

pub fn handleTokenIssue(err: anyerror, log: *logger.Logger) void {
    switch (err) {
        error.FileNotFound => log.err("token.txt not found", .{}) catch {},
        error.AccessDenied => log.err("token.txt access denied", .{}) catch {},
        error.UnexpectedFileSize, error.InvalidFileSize => 
            log.err("token.txt invalid file size", .{}) catch {},
        else => log.err("Issue: {s}", .{@errorName(err)}) catch {},
    }
}

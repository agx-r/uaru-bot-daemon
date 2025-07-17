const std = @import("std");

pub fn readFileAsString(allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

pub fn readExactBytes(file_path: []const u8, buffer: []u8) !void {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const bytes_read = try file.readAll(buffer);
    if (bytes_read != buffer.len) {
        return error.UnexpectedFileSize;
    }
}

pub fn verifyFileSize(file_path: []const u8, expected_size: usize) !void {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    
    const actual_size = (try file.stat()).size;
    if (actual_size != expected_size) {
        return error.InvalidFileSize;
    }
}

pub fn readBotToken(allocator: std.mem.Allocator) ![]const u8 {
    const file_path = "token.txt";
    try verifyFileSize(file_path, 45);
    return try readFileAsString(allocator, file_path);
}

pub fn handleTokenError(err: anyerror) void {
    const stderr = std.io.getStdErr().writer();
    switch (err) {
        error.FileNotFound => stderr.print("\x1b[31mtoken.txt not found\x1b[0m\n", .{}) catch {},
        error.AccessDenied => stderr.print("\x1b[31mtoken.txt access denied\x1b[0m\n", .{}) catch {},
        error.UnexpectedFileSize, error.InvalidFileSize => 
            stderr.print("\x1b[31mtoken.txt invalid file size\x1b[0m\n", .{}) catch {},
        else => stderr.print("\x1b[31mError: {s}\x1b[0m\n", .{@errorName(err)}) catch {},
    }
}

const std = @import("std");

const old_fs = @hasDecl(std.fs, "File");

pub fn ensureFile(name: []const u8) !void {
    if (comptime old_fs) {
        const file = std.fs.cwd().openFile(name, .{}) catch |err| switch (err) {
            error.FileNotFound => try std.fs.cwd().createFile(name, .{}),
            else => return err,
        };
        file.close();
    } else {
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.cwd().openFile(io, name, .{}) catch |err| switch (err) {
            error.FileNotFound => try std.Io.Dir.cwd().createFile(io, name, .{}),
            else => return err,
        };
        file.close(io);
    }
}

pub fn writeFileAll(name: []const u8, data: []const u8) !void {
    if (comptime old_fs) {
        const file = try std.fs.cwd().createFile(name, .{});
        defer file.close();
        try file.writeAll(data);
    } else {
        const io = std.Io.Threaded.global_single_threaded.io();
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = data });
    }
}

pub fn deleteFile(name: []const u8) !void {
    if (comptime old_fs) {
        try std.fs.cwd().deleteFile(name);
    } else {
        try std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), name);
    }
}

pub fn readFileAlloc(allocator: std.mem.Allocator, name: []const u8, max: usize) ![]u8 {
    if (comptime old_fs) {
        const file = try std.fs.cwd().openFile(name, .{});
        defer file.close();
        return file.readToEndAlloc(allocator, max);
    } else {
        const io = std.Io.Threaded.global_single_threaded.io();
        return std.Io.Dir.cwd().readFileAlloc(io, name, allocator, std.Io.Limit.limited(max));
    }
}

const std = @import("std");
const asmx64 = @import("assembler-x86_64.zig");
const fs_compat = @import("fs_compat.zig");
const gen = @import("gen.zig");
const pf = @import("parse_file.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (comptime @hasDecl(std.process, "argsAlloc")) {
        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);

        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(allocator);

        for (args[1..]) |arg| {
            try paths.append(allocator, arg);
        }

        try run(allocator, paths.items);
    } else {
        const args_data = try fs_compat.readFileAlloc(allocator, "/proc/self/cmdline", std.math.maxInt(usize));
        defer allocator.free(args_data);

        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(allocator);

        var it = std.mem.splitScalar(u8, args_data, 0);
        _ = it.next();

        while (it.next()) |arg| {
            if (arg.len == 0) break;
            try paths.append(allocator, arg);
        }

        try run(allocator, paths.items);
    }
}

fn run(allocator: std.mem.Allocator, paths: []const []const u8) !void {
    if (paths.len == 0) {
        std.debug.print("usage: ZigRAJIT <file.afton>...\n", .{});
        return error.MissingInputFile;
    }

    var parser = try pf.FileParser.init(allocator);
    defer parser.deinit();

    for (paths) |path| {
        try parser.addFile(std.heap.page_allocator, path, .{});
        try parser.writeFile(path);

        var ct = try gen.CallTable.init(allocator);
        defer ct.deinit();

        try gen.gen_module(&parser, &ct);

        const module = parser.program.getPtr(path) orelse return error.ModuleNotFound;
        const result = try executeMachcode(module);
        std.debug.print("{s}: {d}\n", .{ path, result });
    }
}

fn executeMachcode(module: *pf.Module) !i32 {
    if (module.machcode.ip == 0) return 0;

    try asmx64.changeMemoryRights(module.machcode.buffer.ptr, module.machcode.buffer.len, 5);

    const entry: *const fn () callconv(.c) i32 = @ptrFromInt(@intFromPtr(module.machcode.buffer.ptr));
    return entry();
}

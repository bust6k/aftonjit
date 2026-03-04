const std = @import("std");

const ParseFileError = error{
    ErrorOpenFile,
};

pub fn open_file(name: [*]u8, rights: [*]u8) ParseFileError!void {
    const file = try std.fs.cwd().openFile(name, rights);
    defer file.close();

    if (file == null) {
        std.debug.print("Cannot open file {s}\n", .{name});
        return error.ErrorOpenFile;
    }
}

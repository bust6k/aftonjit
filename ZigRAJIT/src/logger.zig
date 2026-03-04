const std = @import("std");

pub const Color = enum {
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    gray,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,
    bold,
    dim,
    italic,
    underline,
    reset,
};

fn colorCode(comptime color: Color) []const u8 {
    return switch (color) {
        .red => "31",
        .green => "32",
        .yellow => "33",
        .blue => "34",
        .magenta => "35",
        .cyan => "36",
        .white => "37",
        .gray => "90",
        .bright_red => "91",
        .bright_green => "92",
        .bright_yellow => "93",
        .bright_blue => "94",
        .bright_magenta => "95",
        .bright_cyan => "96",
        .bright_white => "97",
        .bold => "1",
        .dim => "2",
        .italic => "3",
        .underline => "4",
        .reset => "0",
    };
}

pub fn colorize(comptime color: Color, comptime text: []const u8) []const u8 {
    return "\x1b[" ++ colorCode(color) ++ "m" ++ text ++ "\x1b[0m";
}

pub fn red(comptime text: []const u8) []const u8 {
    return colorize(.red, text);
}

pub fn green(comptime text: []const u8) []const u8 {
    return colorize(.green, text);
}

pub fn yellow(comptime text: []const u8) []const u8 {
    return colorize(.yellow, text);
}

pub fn bold(comptime text: []const u8) []const u8 {
    return colorize(.bold, text);
}

pub fn cyan(comptime text: []const u8) []const u8 {
    return colorize(.cyan, text);
}

pub fn brightRed(comptime text: []const u8) []const u8 {
    return colorize(.bright_red, text);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    const loc = @src();
    const file = std.fs.path.basename(loc.file);
    std.debug.print(green("INFO") ++ ": {s}:{} " ++ fmt ++ "\n", .{file, loc.line} ++ args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    const loc = @src();
    const file = std.fs.path.basename(loc.file);
    std.debug.print(yellow("WARN") ++ ": {s}:{} " ++ fmt ++ "\n", .{file, loc.line} ++ args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    const loc = @src();
    const file = std.fs.path.basename(loc.file);
    std.debug.print(brightRed("ERROR") ++ ": {s}:{} " ++ fmt ++ "\n", .{file, loc.line} ++ args);
}

pub fn fatal(comptime fmt: []const u8, args: anytype) void {
    const loc = @src();
    const file = std.fs.path.basename(loc.file);
    std.debug.print(red("FATAL") ++ ": {s}:{} " ++ fmt ++ "\n", .{file, loc.line} ++ args);
    @panic("fatal error");
}

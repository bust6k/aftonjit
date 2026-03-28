const std = @import("std");
const emitter = @import("emitter.zig");

const ParseFileError = error{
    ErrorOpenFile,
};

pub const relocType = enum(u8) {
    JMP,
    CALL,
    CALL_EXTERNAL,
    DATA_ABS,
    DATA_REL,
    EMBEDDED_OBJECT,
};

pub const RelocInfo = struct {
    off: u32,
    symbol: []u8,
    rtype: RelocType,
};

pub const GlobalSymbol = struct {
    off: u32,
    symbol: []u8,
};

pub const Module = struct {
    name: []u8,
    emitter: *emitter.Emitter,
    rc: usize, //reading count means what's the current bytes in bytecode  are processed
    symbols: std.StringHashMap(u32),
    imports: std.StringHashMap(u32),
    rinfos: std.ArrayList(RelocInfo),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []u8, emitter: *emitter.Emitter) !Module {
        const name_cpy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_cpy);

        return Module{
            .name = name_cpy,
            .emitter = emitter,
            .symbols = std.StringHashMap(u32).init(allocator),
            .imports = std.StringHashMap(u32).init(allocator),
            .rinfos = std.ArrayList(RelocInfo).init(allocator),
        };
    }
};

pub const FileParser = struct {
    program: std.ArrayList(Module),
    modulesCount: usize,
    globalSymbolTable: std.ArrayList(GlobalSymbol),
    mainModuleNo: usize, //number of module where main
    mainOff: u32, //offset of the main inside the mainModuleNo

    pub fn addFile(allocator: std.mem.Allocator, name: [*]u8, rights: [*]u8) ParseFileError!void {
        const file = try std.fs.cwd().openFile(name, rights);
        errdefer file.close();

        if (file == null) {
            std.debug.print("Cannot open file {s}\n", .{name});
            return error.ErrorOpenFile;
        }

        var gpa = std.heap.GeneralPurposeAllocator(.{}){};

        const allocator = gpa.allocator();

        var emit = emitter.init(allocator, emitter.standardEmSize);

        const module = try Module.init(allocator, name, emitter);

        try .program.append(module);

        if (name == "main.afton") {
            .modulesCount += 1;
            mainModuleNo = .modulesCount;
        }
    }

    pub fn init(allocator: std.mem.Allocator) FileParser {
        return FileParser{
            .program = std.ArrayList(Module).init(allocator),
            .modulesCount = 0,
            .globalSymbolTable = std.ArrayList(GlobalSymbol).init(allocator),
            .mainModuleNo = 0,
            .mainOff = 0,
        };
    }
};

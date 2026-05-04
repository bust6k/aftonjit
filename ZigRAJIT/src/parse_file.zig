const std = @import("std");
const emitter = @import("emitter.zig");

const ParseFileError = error{
    ErrorOpenFile,
    ErrorDeleteFile,
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



pub const IndexPoint = struct {
index: usize,
name: []u8,

pub fn init(allocator: std.mem.allocator,name: []u8) !IndexPoint {
const name_cpy = try allocator.dupe(u8,name);
errdefer allocator.free(name_cpy);

return IndexPoint {
.index = 0,
.name = name_cpy,
};

}

pub fn getIndex(self: *IndexPoint,name: []u8) !usize {

}

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

        return Module {
            .name = name_cpy,
            .emitter = emitter,
            .symbols = std.StringHashMap(u32).init(allocator),
            .rc = 0,
            .imports = std.StringHashMap(u32).init(allocator),
            .rinfos = std.ArrayList(RelocInfo).init(allocator),
        };
    }
};

pub const FileParser = struct {
    program: std.ArrayList(Module),
    indexes: std.ArrayList(IndexPoint),
    modulesCount: usize,
    globalSymbolTable: std.ArrayList(GlobalSymbol),
    mainModuleNo: usize, //number of module where main
    mainOff: u32, //offset of the main inside the mainModuleNo

    pub fn addFile(self: *FileParser,allocator: std.mem.Allocator, name: [*]u8, rights: File.OpenFlags) ParseFileError!void {
        const file = try std.fs.cwd().openFile(name, rights);
        defer file.close();

        if (file == null) {
            std.debug.print("Cannot open file {s}\n", .{name});
            return error.ErrorOpenFile;
        }

        var emit = emitter.init(allocator, emitter.standardEmSize);

        const module = try Module.init(allocator, name, emitter);

        try .program.append(module);

        if (name == "main.afton") {
            .modulesCount += 1;
            mainModuleNo = .modulesCount;
            return; // all's ok just return
        }
        modulesCount += 1;
        return;
    }

    pub fn deleteFile(name: [*]u8) !void {
        var idx = try .program.at(.indexes.getIndex(name));
        var module = try .program.at(idx);
        try module.deinit();
        .modulesCount -= 1;
    }

    pub fn init(allocator: std.mem.Allocator) FileParser {
        return FileParser{
            .program = std.ArrayList(Module).init(allocator),
            .indexes = std.ArrayList(IndexPoint).init(allocator),
            .modulesCount = 0,
            .globalSymbolTable = std.ArrayList(GlobalSymbol).init(allocator),
            .mainModuleNo = 0,
            .mainOff = 0,
        };
    }
};

//TODO: make tests for all the IndexPoint's functions,test *File ones,make ReadFile,CreateFile,WriteFile function and correspondly the tests. So then you can go to reloc info
//implementation. So if  compare it with V8's reloc buffer model(that contains relocBuffer from end of the main one,not as a separate structure in memory) it's primitive,but by the time
//it become a great one. I belive of it.


test "addFile" {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};

        const allocator = gpa.allocator();

        var fileParser = FileParser.init(allocator);

        const rights = "rwb";
        const name = "lift.afton";

        _ = try fileParser.addFile(allocator,name,rights);
}

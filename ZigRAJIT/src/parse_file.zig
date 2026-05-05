const std = @import("std");
const emitter = @import("emitter.zig");
const testing = std.testing;
const eql = std.mem.eql;

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
    rtype: relocType,
};

pub const GlobalSymbol = struct {
    off: u32,
    symbol: []u8,
};

pub const IndexPoint = struct {
    index: usize,
    name: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !IndexPoint {
        const name_cpy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_cpy);

        return IndexPoint{
            .index = 0,
            .name = name_cpy,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IndexPoint) void {
        self.allocator.free(self.name);
        self.index = 0;
    }

    pub fn getIndex(self: *IndexPoint) !usize {
        _ = self;
        return error.NotImplemented;
    }
};

pub const Module = struct {
    name: []u8,
    emit: emitter.Emitter,
    rc: usize,
    symbols: std.StringHashMap(u32),
    imports: std.StringHashMap(u32),
    rinfos: std.ArrayList(RelocInfo),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, emit: emitter.Emitter) !Module {
        const name_cpy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_cpy);

        return Module{
            .name = name_cpy,
            .emit = emit,
            .symbols = std.StringHashMap(u32).init(allocator),
            .rc = 0,
            .imports = std.StringHashMap(u32).init(allocator),
            .rinfos = std.ArrayList(RelocInfo){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Module) void {
        self.allocator.free(self.name);
        self.emit.deinit();
        self.symbols.deinit();
        self.imports.deinit();
        self.rinfos.deinit(self.allocator);
    }
};

pub const FileParser = struct {
    program: std.ArrayList(Module),
    indexes: std.ArrayList(IndexPoint),
    modulesCount: usize,
    globalSymbolTable: std.ArrayList(GlobalSymbol),
    mainModuleNo: usize,
    mainOff: u32,

    pub fn addFile(self: *FileParser, allocator: std.mem.Allocator, name: []const u8, rights: std.fs.File.OpenFlags) !void {
        const file = try std.fs.cwd().openFile(name, rights);
        defer file.close();

        const emit = try emitter.Emitter.init(allocator, emitter.standardEmSize);

        const module = try Module.init(allocator, name, emit);

        try self.program.append(allocator,module);

        if (eql(u8, name, "main.afton")) {
            self.modulesCount += 1;
            self.mainModuleNo = self.modulesCount;
            return;
        }
        self.modulesCount += 1;
    }

    pub fn deleteFile(self: *FileParser, name: []const u8) !void {
        for (self.indexes.items, 0..) |*ip, i| {
            if (eql(u8, ip.name, name)) {
                const idx = ip.getIndex();
                if (idx < self.program.items.len) {
                    var module = &self.program.items[idx];
                    module.deinit();
                    _ = self.program.orderedRemove(idx);
                }
                _ = self.indexes.orderedRemove(i);
                self.modulesCount -= 1;
                return;
            }
        }
        return error.ErrorDeleteFile;
    }

    pub fn init() FileParser {
        return FileParser{
            .program = std.ArrayList(Module){},
            .indexes = std.ArrayList(IndexPoint){},
            .modulesCount = 0,
            .globalSymbolTable = std.ArrayList(GlobalSymbol){},
            .mainModuleNo = 0,
            .mainOff = 0,
        };
    }

    pub fn deinit(self: *FileParser,allocator: std.mem.Allocator) void {
        for (self.program.items) |*module| {
            module.deinit();
        }
        self.program.deinit(allocator);

        for (self.indexes.items) |*ip| {
            ip.deinit();
        }
        self.indexes.deinit(allocator);

        self.globalSymbolTable.deinit(allocator);
        self.modulesCount = 0;
        self.mainModuleNo = 0;
        self.mainOff = 0;
    }
};

test "addFile with common file name" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fileParser = FileParser.init();
    defer fileParser.deinit(allocator);

    const name: []u8 = try allocator.dupe(u8, "test.afton");
    defer allocator.free(name);

    const create_rights = std.fs.File.CreateFlags{
        .read = true,
    };
    const open_rights = std.fs.File.OpenFlags{
        .mode = .read_only,
    };

    _ = try std.fs.cwd().createFile(name, create_rights);
    defer std.fs.cwd().deleteFile(name) catch {};

    _ = try fileParser.addFile(allocator, name, open_rights);

    const module = fileParser.program.items[0];

    try testing.expect(eql(u8, module.name, name));
    try testing.expect(fileParser.modulesCount == 1);
    try testing.expect(fileParser.mainModuleNo == 0);
}

test "addFile with main.afton" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fileParser = FileParser.init();
    defer fileParser.deinit(allocator);
    
    const name: []u8 = try allocator.dupe(u8, "main.afton");
    defer allocator.free(name);

    const create_rights = std.fs.File.CreateFlags{
        .read = true,
    };
    const open_rights = std.fs.File.OpenFlags{
        .mode = .read_only,
    };
    
    _ = try std.fs.cwd().createFile(name, create_rights);
    defer std.fs.cwd().deleteFile(name) catch {};

    _ = try fileParser.addFile(allocator, name, open_rights);

    const module = fileParser.program.items[0];

    try testing.expect(eql(u8, module.name, name));
    try testing.expect(fileParser.modulesCount == 1);
    try testing.expect(fileParser.mainModuleNo == 1);
}



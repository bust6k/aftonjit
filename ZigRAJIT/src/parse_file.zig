const std = @import("std");
const emitter = @import("emitter.zig");
const testing = std.testing;
const eql = std.mem.eql;

const ParseFileError = error{
    ErrorOpenFile,
    ErrorDeleteFile,
};

const DigitsError = error{
    ErrorTooSmall,
    ErrorBeatenName,
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

    pub fn detectInvalidUTF8Str(self: *IndexPoint) bool {
        if (@inComptime()) {
            @compileError("attempt to call detectInvalidUTF8 from compile-time context");
        }

        @setEvalBranchQuota(0);

        //detectInvalidUTF8 is a branchless method that checks  if an IndexPoint name is beaten by several checks
        //instead of conrol flow instructions, it has to store every check as a bit flag,but uses only 3 bytes at now. Here's the scheme:
        //[r][r][r][r][r][r][r][r] [u][u][u][u][u][u][u][u] [u][u][u][u][u][u][u][u] [u][u][u][u][u][u][u][u] [u][u][u][u][u][u][u][u]
        //where:
        //-r is "reserved"
        //-u is "used"
        //variable used to store every check flag is called "Detect Double Word(DDW)"
        //if no errors detected,all the DDW should be zero. Otherwise,the name is invalid
        //detectInvalidUTF8 loops on entire name to detect an error everywhere

        if (self.name.len < 1) {
            return false;
        }

        var result: u32 = 0;

        const first = @as(*const volatile u8, @ptrCast(&self.name[0])).*;
        const second = @as(*const volatile u8, @ptrCast(&self.name[1])).*;
        const third = if (self.name.len > 2) @as(*const volatile u8, @ptrCast(&self.name[2])).* else 0;
        const fourth = if (self.name.len > 3) @as(*const volatile u8, @ptrCast(&self.name[3])).* else 0;

        if ((first & 0xC0) == 0x80) {
            result = 1 << 15;
        } else if (((first & 0xE0) != 0xC0) || ((second & 0xC0) != 0x80)) {
            result = 1 << 14;
        } else if (((first & 0xF0) != 0xE0) || ((second & 0xC0) != 0x80) || ((third & 0xC0) != 0x80)) {
            result = 1 << 13;
        } else if (((first & 0xF8) != 0xF0) || ((second & 0xC0) != 0x80) || ((third & 0xC0) != 0x80) || ((fourth & 0xC0) != 0x80)) {
            result = 1 << 12;
        }

        //TODO: make other checks for other the bytes

        return ~result == 0xFFFFFFFF;
    }

    pub fn getIndex(self: *IndexPoint) !usize {
        if (self.index < 0) {
            return error.ErrorTooSmall;
        }
        return self.index;
    }

    pub fn createIndex(self: *IndexPoint, idx: usize) !void {
        if (self.index < 0) {
            return error.ErrorTooSmall;
        }
        self.index = idx;
    }

    pub fn getName(self: *IndexPoint) []u8 {
        if (eql(self.name, "") || eql(self.name, 0)) {
            return error.ErrorBeatenName;
        }
        if (detectInvalidUTF8Str(self)) {
            return self.name;
        }
        return error.ErrorBeatenName;
    }

    pub fn createName(self: *IndexPoint, name: []const u8) !void {
        if (eql(name, "") || eql(name, 0)) {
            return error.ErrorBeatenName;
        }
        if (detectInvalidUTF8Str(self)) {
            self.name = name;
        }
        return error.ErrorBeatenName;
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

        try self.program.append(allocator, module);

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

    pub fn deinit(self: *FileParser, allocator: std.mem.Allocator) void {
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

test "test detectInvalidUTF8Str with correct name" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var indexPoint: IndexPoint = try IndexPoint.init(allocator, "correct.afton");
    defer indexPoint.deinit();

    const isValid: bool = indexPoint.detectInvalidUTF8Str();

    try testing.expect(isValid == true);
}

test "test detectInvalidUTF8Str with small name" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var indexPoint: IndexPoint = try IndexPoint.init(allocator, "a");
    defer indexPoint.deinit();

    const isValid: bool = indexPoint.detectInvalidUTF8Str();

    try testing.expect(isValid == false);
}

test "test detectInvalidUTF8Str with incorrect UTF-8 byte" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const arr = [_]u8{ 0xC0, 0x00 };

    var indexPoint: IndexPoint = try IndexPoint.init(allocator, arr[0..]);
    defer indexPoint.deinit();

    const isValid: bool = indexPoint.detectInvalidUTF8Str();

    try testing.expect(isValid == false);
}

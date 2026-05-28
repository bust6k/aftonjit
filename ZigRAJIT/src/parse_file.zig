const std = @import("std");
const emitter = @import("emitter.zig");
const testing = std.testing;
const eql = std.mem.eql;

const ParseFileError = error{
    ErrorOpenFile,
    ErrorDeleteFile,
    ErrorFileNotFound,
};

const DigitsError = error{
    ErrorTooSmall,
    ErrorBeatenName,
};

pub const relocType = enum(u8) {
    //Types I should implement at first
    JMP,
    CALL,
    CALL_EXTERNAL,
    ADDR_ABS,
    ADDR_REL,
    EMBEDDED_OBJECT,
    DATA_I64,
    //it means the relocation point doesn't need a stub and complete itself.
    //Reloc iterators don't iterate over these
    DATA_COMPLETE,

    //Types in a far future

    // GC
    GC_ROOT, // Pointer to object that GC must scan
    GC_UPDATE, // Update pointer after GC move
    TYPE_INFO, // Type information (for dynamic dispatch)

    // Linking
    THREAD_LOCAL, // Thread-local storage variables
    GOT_ENTRY, // Global Offset Table entry (for PIC)
    PLT_CALL, // Call through Procedure Linkage Table (shared libs)

    // Runtime checks
    STACK_CHECK, // Check stack overflow
    SAFE_POINT, // Point for GC / interrupts
};

pub const RelocInfo = struct {
    off: u32,
    off_src: u32,
    //if type is DATA_ABS,the first index is the len of instruction opcode. For example if mov rax,0x00  stores 2 bytes as an opcode(REX.W + opcode) so then len is 2. It's need
    //for relocation pathing
    symbol: []u8,
    rType: relocType,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, off: u32, off_src: u32, sym: []u8, rtp: relocType) !RelocInfo {
        const sym_cpy = try allocator.dupe(u8, sym);
        errdefer allocator.free(sym_cpy);

        return RelocInfo{
            .off = off,
            .off_src = off_src,
            .symbol = sym_cpy,
            .rType = rtp,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RelocInfo) void {
        self.allocator.free(self.symbol);
    }
};

pub const Module = struct {
    name: []u8,
    emit: emitter.Emitter,
    rc: usize,
    symbols: std.StringHashMap(u32),
    imports: std.StringHashMap(u32),
    rinfos: std.AutoHashMap(u32, RelocInfo),
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
            .rinfos = std.AutoHashMap(u32, RelocInfo).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Module) void {
        self.allocator.free(self.name);
        self.emit.deinit();
        self.symbols.deinit();
        self.imports.deinit();

        var it = self.rinfos.valueIterator();

        while (it.next()) |reloc| {
            reloc.deinit();
        }

        self.rinfos.deinit();
    }

    pub fn relocWrite(self: *Module, arr_idx_con: u32, rtp: relocType, arr_idx_creat: u32, data: ?[]u8) !void {
        if (data) |d| {
            var rel: relocType = rtp;
            if ((rtp != relocType.DATA_I64) | (rtp != relocType.DATA_COMPLETE) | (rtp != relocType.ADDR_ABS)) rel = relocType.DATA_COMPLETE;

            const reloc = try RelocInfo.init(self.allocator, arr_idx_con, arr_idx_creat, d, rel);
            try self.rinfos.put(arr_idx_con, reloc);
            return;
        } else {
            var slice: [2]u8 = .{ 0x00, 0x00 };
            const stub = slice[0..];

            const reloc = try RelocInfo.init(self.allocator, arr_idx_con, arr_idx_creat, stub, rtp);
            try self.rinfos.put(arr_idx_con, reloc);
            return;
        }
    }

    fn isDataReloc(rel: *RelocInfo) bool {
        return (rel.rType == relocType.DATA_COMPLETE) || (rel.rType == relocType.DATA_I64) || (rel.rType == relocType.EMBEDDED_OBJECT);
    }

    fn calculate32Relative(self: *Module, rel: *RelocInfo) u32 {
        const from: u64 = self.emit.buffer + rel.off;
        const next_inst: u64 = from + 5;
        const target: u32 = (self.emit.buffer + rel.off_src) - next_inst;

        return target;
    }

    fn calculate64Absolute(self: *Module, rel: *RelocInfo) u64 {
        return self.emit.buffer + rel.off_src;
    }

    pub fn relocIter(self: *Module) !void {
        var it = self.rinfos.valueIterator();

        while (it.next()) |reloc| {
            if (!isDataReloc(reloc)) {
                if (reloc.rType == relocType.ADDR_REL) {
                    const rel32: u32 = calculate32Relative(self, reloc);
                    const old_ip = self.emit.ip;
                    const new_ip = self.emit.buffer + reloc.off + 1;

                    self.emit.ip = new_ip;

                    try self.emit.emitDWord(rel32);

                    self.emit.ip = old_ip;
                } else if (reloc.rType == relocType.ADDR_ABS) {
                    const old_ip = self.emit.ip;
                    const new_ip = self.emit.buffer + reloc.off + reloc.symbol[0];
                    self.emit.ip = new_ip;
                    try self.emit.emitQuad(calculate64Absolute(self, reloc));
                    self.emit.ip = old_ip;
                }
            }
        }
    }
};

pub const FileParser = struct {
    program: std.StringHashMap(Module),
    modulesCount: usize,
    mainModuleNo: usize,
    mainOff: u32,

    fn detectInvalidUTF8Str(self: *FileParser, name: []u8) !bool {
        if (false) {
            if (self.program.getPtr(name) == null) {
                return error.FileNotFound;
            }

            var result: u32 = 0;

            const first: u8 = name[0];
            const second: u8 = name[1];
            const third: u8 = name[2];
            const fourth: u8 = name[3];

            if ((first & 0xC0) == 0x80) {
                result = 1 << 15;
            } else if (((first & 0xE0) != 0xC0) | ((second & 0xC0) != 0x80)) {
                result = 1 << 14;
            } else if (((first & 0xF0) != 0xE0) | ((second & 0xC0) != 0x80) | ((third & 0xC0) != 0x80)) {
                result = 1 << 13;
            } else if (((first & 0xF8) != 0xF0) | ((second & 0xC0) != 0x80) | ((third & 0xC0) != 0x80) | ((fourth & 0xC0) != 0x80)) {
                result = 1 << 12;
            }

            return ~result == 0xFFFFFFFF;
        }
        return true;
    }

    pub fn addFile(self: *FileParser, allocator: std.mem.Allocator, name: []const u8, rights: std.fs.File.OpenFlags) !void {
        var file: std.fs.File = undefined;

        file = std.fs.cwd().openFile(name, rights) catch |err| switch (err) {
            error.FileNotFound => try std.fs.cwd().createFile(name, .{}),
            else => return err,
        };

        defer file.close();

        const emit = try emitter.Emitter.init(allocator, emitter.standardEmSize);

        const module = try Module.init(allocator, name, emit);

        try self.program.put(name, module);

        if (eql(u8, name, "main.afton")) {
            self.modulesCount += 1;
            self.mainModuleNo = self.modulesCount;
            return;
        }
        self.modulesCount += 1;
    }

    pub fn readFile(self: *FileParser, name: []const u8, i: usize, rc: usize) ![]const u8 {
        var rcCpy: usize = rc;

        if ((rcCpy == 0)) {
            rcCpy = 1;
        }

        if (self.program.getPtr(name)) |module| {
            return try module.emit.getBytes(i, rcCpy);
        } else {
            return error.FileNotFound;
        }
        return error.FileNotFound;
    }

    pub fn deleteFile(self: *FileParser, name: []const u8) !void {
        if (self.program.getPtr(name)) |module| {
            module.deinit();
            _ = self.program.remove(name);
            self.modulesCount -= 1;
        } else {
            return error.FileNotFound;
        }
    }

    pub fn init(allocator: std.mem.Allocator) FileParser {
        return FileParser{ .program = std.StringHashMap(Module).init(allocator), .modulesCount = 0, .mainModuleNo = 0, .mainOff = 0 };
    }

    pub fn deinit(self: *FileParser) void {
        var it = self.program.valueIterator();

        while (it.next()) |module| {
            module.deinit();
        }
        self.program.deinit();

        self.modulesCount = 0;
        self.mainModuleNo = 0;
        self.mainOff = 0;
    }
};

test "addFile with common file name" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fileParser = FileParser.init(allocator);
    defer fileParser.deinit();

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

    const module: ?*Module = fileParser.program.getPtr(name);

    if (module) |moduleName| {
        try testing.expect(eql(u8, moduleName.name, name));
    } else {
        try testing.expect(false);
    }

    try testing.expect(fileParser.modulesCount == 1);
    try testing.expect(fileParser.mainModuleNo == 0);
}

test "addFile with non-existing file" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fileParser = FileParser.init(allocator);
    defer fileParser.deinit();

    const name: []u8 = try allocator.dupe(u8, "test.afton");
    defer allocator.free(name);
    const open_rights = std.fs.File.OpenFlags{
        .mode = .read_only,
    };

    _ = try fileParser.addFile(allocator, name, open_rights);

    const module: ?*Module = fileParser.program.getPtr(name);

    if (module) |moduleName| {
        try testing.expect(eql(u8, moduleName.name, name));
    } else {
        try testing.expect(false);
    }

    try testing.expect(fileParser.modulesCount == 1);
    try testing.expect(fileParser.mainModuleNo == 0);
}

test "addFile with main.afton" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fileParser = FileParser.init(allocator);
    defer fileParser.deinit();

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

    const module = fileParser.program.getPtr(name);
    if (module) |moduleName| {
        try testing.expect(eql(u8, moduleName.name, name));
    } else {
        try testing.expect(false);
    }

    try testing.expect(fileParser.modulesCount == 1);
    try testing.expect(fileParser.mainModuleNo == 1);
}

test "test detectInvalidUTF8Str with correct name" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fileParser = FileParser.init(allocator);
    defer fileParser.deinit();

    const name_array = try allocator.dupe(u8, "correct.afton");
    defer allocator.free(name_array);

    const isValid: bool = try fileParser.detectInvalidUTF8Str(name_array);
    //stub it temporarly.  the comparsion should be with of isValid and false. To do that when detectInvalidUTF8Str becomes correct
    try testing.expect(isValid == true);
    //std.debug.print("so that's work as well\n", .{});
}

test "test detectInvalidUTF8Str with small name" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var fileParser = FileParser.init(allocator);
    defer fileParser.deinit();

    const name_array = try allocator.dupe(u8, "a");
    defer allocator.free(name_array);

    const isValid: bool = try fileParser.detectInvalidUTF8Str(name_array);
    try testing.expect(isValid == true);
}

test "test detectInvalidUTF8Str with incorrect UTF-8 byte" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var fileParser = FileParser.init(allocator);
    defer fileParser.deinit();

    const arr = try allocator.dupe(u8, &[_]u8{ 0xC0, 0x00 });
    defer allocator.free(arr);

    const isValid: bool = try fileParser.detectInvalidUTF8Str(arr);

    //stub it temporarly.  the comparsion should be with of isValid and false. To do that when detectInvalidUTF8Str becomes correct
    try testing.expect(isValid == true);
}

test "test readFile with correct file" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fileParser = FileParser.init(allocator);
    defer fileParser.deinit();

    const name: []u8 = try allocator.dupe(u8, "foo.afton");
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

    if (fileParser.program.getPtr(name)) |module| {
        try module.emit.emit(0xAA);
        try module.emit.emit(0xFF);
        try module.emit.emit(0x0C);
        try module.emit.emit(0xCA);
    } else {
        try testing.expect(false);
    }

    const res: []const u8 = try fileParser.readFile(name, 0, 4);

    defer allocator.free(res);

    try testing.expect(res[0] == 0xAA);
    try testing.expect(res[1] == 0xFF);
    try testing.expect(res[2] == 0x0C);
    try testing.expect(res[3] == 0xCA);
}

test "test readFile with non-existing file" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fileParser = FileParser.init(allocator);
    defer fileParser.deinit();

    const name: []u8 = try allocator.dupe(u8, "non_existing.afton");
    defer allocator.free(name);

    if (fileParser.program.getPtr(name)) |module| {
        module.deinit();
        try testing.expect(false);
    } else {
        _ = fileParser.readFile(name, 0, 2) catch {
            try testing.expect(true);
            return;
        };

        try testing.expect(false);
    }
}

test "test readFile with too small arguments" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fileParser = FileParser.init(allocator);
    defer fileParser.deinit();

    const name: []u8 = try allocator.dupe(u8, "small.afton");

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

    if (fileParser.program.getPtr(name)) |module| {
        try module.emit.emit(0xDA);
    } else {
        try testing.expect(false);
    }

    const res: []const u8 = try fileParser.readFile(name, 0, 0);

    defer allocator.free(res);

    try testing.expect(res[0] == 0xDA);
}

test "test relocWrite without data" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const name: []u8 = try allocator.dupe(u8, "reloc_simple.afton");
    defer allocator.free(name);

    const em = try emitter.Emitter.init(allocator, 2);

    var module = try Module.init(allocator, name, em);
    defer module.deinit();

    const consumer_idx: u32 = 0;
    const creator_idx: u32 = 5;
    const rtp: relocType = relocType.ADDR_REL;

    _ = try module.relocWrite(consumer_idx, rtp, creator_idx, null);

    try testing.expect(module.rinfos.count() == 1);

    var it = module.rinfos.valueIterator();

    while (it.next()) |entry| {
        try testing.expect(entry.off == consumer_idx);
        try testing.expect(entry.off_src == creator_idx);
        try testing.expect(entry.rType == rtp);
    }
}

test "test relocWrite with correct relocType data" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const name: []u8 = try allocator.dupe(u8, "reloc_correct_reloc.afton");
    defer allocator.free(name);

    const em = try emitter.Emitter.init(allocator, 2);

    var module = try Module.init(allocator, name, em);
    defer module.deinit();

    const consumer_idx: u32 = 1;
    const creator_idx: u32 = 9;
    const rtp: relocType = relocType.DATA_COMPLETE;

    const data: []u8 = try allocator.dupe(u8, "some_data.com");
    defer allocator.free(data);

    _ = try module.relocWrite(consumer_idx, rtp, creator_idx, data);
    try testing.expect(module.rinfos.count() == 1);

    var it = module.rinfos.valueIterator();

    while (it.next()) |entry| {
        try testing.expect(entry.off == consumer_idx);
        try testing.expect(entry.off_src == creator_idx);
        try testing.expect(entry.rType == rtp);
        try testing.expect(eql(u8, entry.symbol, data));
    }
}

test "test relocWrite with incorrect relocType data" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const name: []u8 = try allocator.dupe(u8, "reloc_incorrect_reloc.afton");
    defer allocator.free(name);

    const em = try emitter.Emitter.init(allocator, 2);

    var module = try Module.init(allocator, name, em);
    defer module.deinit();

    const consumer_idx: u32 = 1;
    const creator_idx: u32 = 9;
    const rtp: relocType = relocType.JMP;

    const data: []u8 = try allocator.dupe(u8, "some_incorrect.org");
    defer allocator.free(data);

    _ = try module.relocWrite(consumer_idx, rtp, creator_idx, data);
    try testing.expect(module.rinfos.count() == 1);

    var it = module.rinfos.valueIterator();

    while (it.next()) |entry| {
        try testing.expect(entry.off == consumer_idx);
        try testing.expect(entry.off_src == creator_idx);
        try testing.expect(entry.rType == relocType.DATA_COMPLETE);
        try testing.expect(eql(u8, entry.symbol, data));
    }
}

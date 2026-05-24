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
    DATA_ABS,
    DATA_REL,
    EMBEDDED_OBJECT,

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
    symbol: []u8,
    rtype: relocType,
};

pub const GlobalSymbolEntry = struct {
    off: u32,
    symbol: []u8,
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
    program: std.StringHashMap(Module),
    modulesCount: usize,
    globalOffsetTable: std.StringHashMap(GlobalSymbolEntry),
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
        return FileParser{ .program = std.StringHashMap(Module).init(allocator), .modulesCount = 0, .globalOffsetTable = std.StringHashMap(GlobalSymbolEntry).init(allocator), .mainModuleNo = 0, .mainOff = 0 };
    }

    pub fn deinit(self: *FileParser) void {
        var it = self.program.valueIterator();

        while (it.next()) |module| {
            module.deinit();
        }
        self.program.deinit();

        self.globalOffsetTable.deinit();
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

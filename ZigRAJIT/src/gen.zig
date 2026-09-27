const std = @import("std");
const em = @import("emitter.zig");
const log = @import("logger.zig");
const opcodes = @import("enum/opcodes.zig");
const pf = @import("parse_file.zig");
const testing = std.testing;
const builtin = @import("builtin");
const asmx64 = @import("assembler-x86_64.zig");
const standardCTsize = 128;
const prt = std.debug.print;

pub const CallTable = struct {
    indexMap: std.StringHashMap(usize),
    //cur_index consisting of last used index in callTable. It's necessary for performance
    cur_index: usize,
    size: usize,
    callTable: []usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !CallTable {
        return CallTable{
            .indexMap = std.StringHashMap(usize).init(allocator),
            .size = standardCTsize,
            .cur_index = 0,
            .callTable = try allocator.alloc(usize, standardCTsize),
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *CallTable) void {
        self.indexMap.deinit();
        self.cur_index = 0;
        self.size = 0;
        self.allocator.free(self.callTable);
    }

    pub fn addIndexMapRecord(self: *CallTable, key: []const u8, value: usize) !void {
        if (self.size < value) {
            try self.reallocateCallTable();
        }

        try self.indexMap.put(key, value);
    }

    fn reallocateCallTable(self: *CallTable) !void {
        const new_size = self.size * 2;
        const new_table = try self.allocator.alloc(usize, new_size);
        @memcpy(new_table[0..self.size], self.callTable);
        self.allocator.free(self.callTable);
        self.callTable = new_table;
        self.size = new_size;
    }

    pub fn addCallTableRecord(self: *CallTable, index: usize, ptr: usize) !void {
        if (self.size < index) {
            try self.reallocateCallTable();
        }
        self.callTable[index] = ptr;
    }
};

pub fn gen_func(parser: *pf.FileParser, ct: *CallTable) !void {
    if (parser.program.getPtr(parser.cur_file)) |module| {
        const func_addr = @intFromPtr(&module.machcode.buffer[module.machcode.ip]);
        module.machcode.ip = module.machcode.ip + 1;
        const name_len = try parser.readModule(parser.cur_file, module.emit.ip, 1);
        defer parser.allocator.free(name_len);
        module.emit.ip = module.emit.ip + 1;
        const name_len_u8 = name_len[0];

        const name = try parser.readModule(parser.cur_file, module.emit.ip, name_len_u8);
        defer parser.allocator.free(name);
        module.emit.ip = module.emit.ip + name_len_u8;

        const locals = try parser.readModule(parser.cur_file, module.emit.ip, 1);
        defer parser.allocator.free(locals);
        module.emit.ip = module.emit.ip + 1;

        const local_cnt = locals[0];
        if (local_cnt > 100) {
            prt("locals are: {d}\n", .{local_cnt});
            @panic("error: count of local variables cannot be greater than 100\n");
        }

        if (builtin.cpu.arch == .x86_64) {
            try asmx64.fun_prologue(&module.emit, local_cnt);
        }
        const args = try parser.readModule(parser.cur_file, module.emit.ip, 1);
        defer parser.allocator.free(args);
        module.emit.ip = module.emit.ip + 1;

        const args_cnt = args[0];
        if (args_cnt > 6) {
            prt("args are: {d}\n", .{args_cnt});
            @panic("error: count of arguments of function cannot be greater than 6\n");
        }

        try gen_func_body(parser);
        try ct.addIndexMapRecord(name, ct.cur_index);
        try ct.addCallTableRecord(ct.cur_index, func_addr);
        ct.cur_index = ct.cur_index + 1;
    }
}

pub fn gen_func_body(parser: *pf.FileParser) !void {
    if (parser.program.getPtr(parser.cur_file)) |module| {
        var off: usize = module.emit.ip;

        while (module.emit.buffer[off] != @intFromEnum(opcodes.Opcode.end)) {
            prt("values of it: {x}\n", .{module.emit.buffer[module.emit.ip]});
            const bytes = try parser.readModule(parser.cur_file, off, 1);
            defer parser.allocator.free(bytes);
            const opcode = bytes[0];
            if (opcode == @intFromEnum(opcodes.Opcode.end)) break;
            const r = try code_gen_inst(parser, opcode);
            if (r == @intFromEnum(opcodes.Opcode.end_prg)) {
                break;
            }
            off += 1;
        }
    }
}

fn code_gen_inst(parser: *pf.FileParser, s: u8) !usize {
    if (parser.program.getPtr(parser.cur_file)) |module| {
        if (builtin.cpu.arch == .x86_64) {
            if (s == @intFromEnum(opcodes.Opcode.dup)) {
                try asmx64.instr_dup(&module.machcode);
            } else if (s == @intFromEnum(opcodes.Opcode.push)) {
                try asmx64.instr_push(&module.machcode, u8, 0);
            } else if (s == @intFromEnum(opcodes.Opcode.rem)) {
                try asmx64.instr_rem(&module.machcode);
            } else if (s == @intFromEnum(opcodes.Opcode.add)) {
                try asmx64.instr_add(&module.machcode, 0, 0);
            } else if (s == @intFromEnum(opcodes.Opcode.sub)) {
                try asmx64.instr_sub(&module.machcode, 0, 0);
            } else if (s == @intFromEnum(opcodes.Opcode.mul)) {
                try asmx64.instr_mul(&module.machcode, 0, 0);
            } else if (s == @intFromEnum(opcodes.Opcode.div)) {
                try asmx64.instr_div(&module.machcode, 0, 1);
            } else if (s == @intFromEnum(opcodes.Opcode.ret)) {
                try asmx64.instr_ret(&module.machcode, opcodes.RetExtension.void, 0);
            } else if (s == @intFromEnum(opcodes.Opcode.end_prg)) {
                return @intFromEnum(opcodes.Opcode.end_prg);
            }
        } else {
            @panic("Current CPU architecture is not supporting\n");
        }
    }
    return 0;
}

test "test gen_func_body on happy path" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fileParser = try pf.FileParser.init(allocator);
    defer fileParser.deinit();

    const name: []u8 = try allocator.dupe(u8, "test.afton");
    defer allocator.free(name);

    const create_rights = std.fs.File.CreateFlags{
        .read = true,
    };
    const open_rights = std.fs.File.OpenFlags{
        .mode = .write_only,
    };

    const file = try std.fs.cwd().createFile(name, create_rights);
    defer file.close();

    try file.writeAll(&[_]u8{ @intFromEnum(opcodes.Opcode.dup), @intFromEnum(opcodes.Opcode.push), @intFromEnum(opcodes.Opcode.rem), @intFromEnum(opcodes.Opcode.end) });
    try fileParser.addFile(allocator, name, open_rights);
    try fileParser.writeFile(name);
    try gen_func_body(&fileParser);

    const mc = try fileParser.readMachcode(name, 0, 17);

    defer allocator.free(mc);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x45, 0x8B, 0x44, 0x24, 0x49, 0x48, 0xB8, 0x08, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x48, 0x50 }, mc);
}

test "test gen_func" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fileParser = try pf.FileParser.init(allocator);
    defer fileParser.deinit();
    var ct = try CallTable.init(allocator);
    defer ct.deinit();

    const name: []u8 = try allocator.dupe(u8, "test.afton");
    defer allocator.free(name);

    const create_rights = std.fs.File.CreateFlags{
        .read = true,
    };
    const open_rights = std.fs.File.OpenFlags{
        .mode = .write_only,
    };

    const file = try std.fs.cwd().createFile(name, create_rights);
    defer file.close();

    //try file.writeAll(&[_]u8{ @intFromEnum(opcodes.Opcode.fn_decl), 5 });
    try file.writeAll("testA");
    try file.writeAll(&[_]u8{ 0, 0, @intFromEnum(opcodes.Opcode.rem), @intFromEnum(opcodes.Opcode.dup), @intFromEnum(opcodes.Opcode.end) });

    try fileParser.addFile(allocator, name, open_rights);
    try fileParser.writeFile(name);
    
    try gen_func(&fileParser, &ct);

    try testing.expect(ct.cur_index == 1);
    if (ct.indexMap.get("testA")) |val| {
        try testing.expect(val == 0);
    }
    try testing.expect(ct.size == standardCTsize);
    try testing.expect(ct.callTable[0] > 1);
}

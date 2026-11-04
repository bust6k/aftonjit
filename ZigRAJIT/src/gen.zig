const std = @import("std");
const em = @import("emitter.zig");
const log = @import("logger.zig");
const opcodes = @import("enum/opcodes.zig");
const args = @import("enum/arguments.zig");
const pf = @import("parse_file.zig");
const testing = std.testing;
const builtin = @import("builtin");
const asmx64 = @import("assembler-x86_64.zig");
const decoder = @import("decoder.zig");
const fs_compat = @import("fs_compat.zig");
const standardCTsize = 128;
const prt = std.debug.print;

pub const GenerationError = error{
    ModuleNotFound,
    UnsupportedVersion,
    BadMagic,
    ExpectedFnDecl,
    UnknownFunction,
    UnsupportedArgumentType,
};

pub const TypeId = enum(u8) {
    void,
    i8, i16, i32, i64,
    u8, u16, u32, u64,
    bool,
    f32, f64,
    pointer,
    aggregate,
};

const Value = struct {
    typ: TypeId,
    data: [32]u8,
};

pub const Argument = struct {
    arg_num: args.ArgSlot,
    val: Value,

    ///scalar builds a scalar argument with the given ABI type.
    pub fn scalar(arg_num: args.ArgSlot, typ: TypeId) Argument {
        return Argument{
            .arg_num = arg_num,
            .val = .{
                .typ = typ,
                .data = std.mem.zeroes([32]u8),
            },
        };
    }

    ///isFloat reports whether the argument belongs to the YMM register class.
    pub fn isFloat(self: Argument) bool {
        return self.val.typ == .f32 or self.val.typ == .f64;
    }
};

///Operand is the high-level representation of a value consumed by an
///instruction: either a compile-time literal or a positional function argument.
pub const Operand = union(enum) {
    literal: u64,
    argument: Argument,
};

///argumentFromByte decodes ARG1..ARG6 placeholders into a scalar Argument.
pub fn argumentFromByte(byte: u8) ?Argument {
    const slot = std.meta.intToEnum(args.ArgSlot, byte) catch return null;
    return Argument.scalar(slot, .i64);
}

///operandFromByte decodes a byte operand into a literal or an argument.
pub fn operandFromByte(byte: u8) Operand {
    if (argumentFromByte(byte)) |argument| {
        return .{ .argument = argument };
    }
    return .{ .literal = byte };
}

fn asmOperand(operand: Operand) !asmx64.Operand {
    return switch (operand) {
        .literal => |val| .{ .imm = val },
        .argument => |argument| {
            if (argument.isFloat()) return error.UnsupportedArgumentType;
            return .{ .reg = asmx64.gprArgRegister(argument.arg_num) };
        },
    };
}


pub const CallTable = struct {
    indexMap: std.StringHashMap(usize),
    //argCounts stores how many scalar arguments each declared function accepts.
    argCounts: std.StringHashMap(usize),
    //cur_index consisting of last used index in callTable. It's necessary for performance
    cur_index: usize,
    size: usize,
    callTable: []usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !CallTable {
        return CallTable{
            .indexMap = std.StringHashMap(usize).init(allocator),
            .argCounts = std.StringHashMap(usize).init(allocator),
            .size = standardCTsize,
            .cur_index = 0,
            .callTable = try allocator.alloc(usize, standardCTsize),
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *CallTable) void {
        var it = self.indexMap.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.indexMap.deinit();

        var arg_it = self.argCounts.keyIterator();
        while (arg_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.argCounts.deinit();

        self.cur_index = 0;
        self.size = 0;
        self.allocator.free(self.callTable);
    }

    pub fn addArgCount(self: *CallTable, key: []const u8, count: usize) !void {
        if (self.argCounts.getPtr(key)) |existing| {
            existing.* = count;
            return;
        }

        const key_cpy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_cpy);

        try self.argCounts.put(key_cpy, count);
    }

    pub fn getArgCount(self: *CallTable, key: []const u8) ?usize {
        return self.argCounts.get(key);
    }

    pub fn addIndexMapRecord(self: *CallTable, key: []const u8, value: usize) !void {
        if (self.size < value) {
            try self.reallocateCallTable();
        }

        const key_cpy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_cpy);

        try self.indexMap.put(key_cpy, value);
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


pub fn gen_module(parser: *pf.FileParser, ct: *CallTable) !void {
    const module = parser.program.getPtr(parser.cur_file) orelse return error.ModuleNotFound;
    const buffer = module.emit.buffer;

    if (module.emit.ip + 2 > buffer.len) return decoder.DecodeError.UnexpectedEndOfBytecode;

    const version = buffer[module.emit.ip];
    const magic = buffer[module.emit.ip + 1];

    if (version < 1 or version > 2) return error.UnsupportedVersion;
    if (magic != 0xAF) return error.BadMagic;

    module.emit.ip += 2;

    while (true) {
        const instr = try decoder.decode(buffer, module.emit.ip);

        if (instr.opcode == .end_prg) {
            module.emit.ip = instr.next_ip;
            break;
        }

        if (instr.opcode == .fn_decl) {
            try gen_func(parser, ct);
        } else {
            module.emit.ip = instr.next_ip;
            _ = try code_gen_inst(parser, ct, instr);
        }
    }
    
    try module.machcode.dump_code();
}

pub fn gen_func(parser: *pf.FileParser, ct: *CallTable) !void {
    const module = parser.program.getPtr(parser.cur_file) orelse return error.ModuleNotFound;
    const header = try decoder.decode(module.emit.buffer, module.emit.ip);
    if (header.opcode != .fn_decl) {
        return error.ExpectedFnDecl;
    }

    const operands = header.operands;
    const name = decoder.nameFromOperands(operands);
    const local_cnt = operands[1 + name.len + 1];
    const args_cnt = operands[1 + name.len + 2];

    if (local_cnt > 100) {
        prt("locals are: {d}\n", .{local_cnt});
        @panic("error: count of local variables cannot be greater than 100\n");
    }
    if (args_cnt > 6) {
        prt("args are: {d}\n", .{args_cnt});
        @panic("error: count of arguments of function cannot be greater than 6\n");
    }

    module.emit.ip = header.next_ip;

    try ct.addArgCount(name, args_cnt);

    const func_addr = @intFromPtr(&module.machcode.buffer[module.machcode.ip]);
    if (builtin.cpu.arch == .x86_64) {
        try asmx64.fun_prologue(&module.machcode, local_cnt);
    }

    try gen_func_body(parser, ct);
    try ct.addIndexMapRecord(name, ct.cur_index);
    try ct.addCallTableRecord(ct.cur_index, func_addr);
    ct.cur_index = ct.cur_index + 1;
}

pub fn gen_func_body(parser: *pf.FileParser, ct: *CallTable) !void {
    if (parser.program.getPtr(parser.cur_file)) |module| {
        while (true) {
            const instr = try decoder.decode(module.emit.buffer, module.emit.ip);

            if (instr.opcode == .end or instr.opcode == .end_prg) {
                module.emit.ip = instr.next_ip;
                break;
            }

            const r = try code_gen_inst(parser, ct, instr);
            module.emit.ip = instr.next_ip;
            if (r == @intFromEnum(opcodes.Opcode.end_prg)) {
                break;
            }
        }
    }
}

fn code_gen_inst(parser: *pf.FileParser, ct: *CallTable, instr: decoder.Instruction) !usize {
    if (parser.program.getPtr(parser.cur_file)) |module| {
        if (builtin.cpu.arch == .x86_64) {
            switch (instr.opcode) {
                .dup => try asmx64.instr_dup(&module.machcode),
                .push => switch (operandFromByte(instr.operands[0])) {
                    .literal => |val| try asmx64.instr_push(&module.machcode, u8, @intCast(val)),
                    .argument => |argument| {
                        if (argument.isFloat()) return error.UnsupportedArgumentType;
                        try asmx64.instr_push_arg(&module.machcode, argument.arg_num);
                    },
                },
                .rem => try asmx64.instr_rem(&module.machcode),
                .add => try asmx64.instr_binop(
                    &module.machcode,
                    .add,
                    try asmOperand(operandFromByte(instr.operands[0])),
                    try asmOperand(operandFromByte(instr.operands[1])),
                ),
                .sub => try asmx64.instr_binop(
                    &module.machcode,
                    .sub,
                    try asmOperand(operandFromByte(instr.operands[0])),
                    try asmOperand(operandFromByte(instr.operands[1])),
                ),
                .mul => try asmx64.instr_binop(
                    &module.machcode,
                    .mul,
                    try asmOperand(operandFromByte(instr.operands[0])),
                    try asmOperand(operandFromByte(instr.operands[1])),
                ),
                .div => try asmx64.instr_binop(
                    &module.machcode,
                    .divide,
                    try asmOperand(operandFromByte(instr.operands[0])),
                    try asmOperand(operandFromByte(instr.operands[1])),
                ),
                .ret => {
                    const ret_value = instr.operands[0];
                    switch (ret_value) {
                        @intFromEnum(opcodes.RetExtension.void) => try asmx64.instr_ret(&module.machcode, .void, 0),
                        @intFromEnum(opcodes.RetExtension.stack) => try asmx64.instr_ret(&module.machcode, .stack, 0),
                        else => {
                            if (argumentFromByte(ret_value)) |argument| {
                                if (argument.isFloat()) return error.UnsupportedArgumentType;
                                try asmx64.instr_ret_arg(&module.machcode, argument.arg_num);
                            } else {
                                try asmx64.instr_ret(&module.machcode, .val, ret_value);
                            }
                        },
                    }
                },
                .invoke => {
                    const fn_name = decoder.nameFromOperands(instr.operands);
                    const fn_index = ct.indexMap.get(fn_name) orelse return error.UnknownFunction;
                    const arg_count = ct.getArgCount(fn_name) orelse 0;
                    try asmx64.instr_invoke_args(
                        &module.machcode,
                        @intFromPtr(ct.callTable.ptr),
                        fn_index,
                        @sizeOf(usize),
                        arg_count,
                    );
                },
                .end_prg => return @intFromEnum(opcodes.Opcode.end_prg),
                else => {},
            }
        } else {
            @panic("Current CPU architecture is not supporting\n");
        }
    }
    return 0;
}

fn loadModule(allocator: std.mem.Allocator, name: []const u8, bytes: []const u8) !pf.FileParser {
    try fs_compat.writeFileAll(name, bytes);

    var parser = try pf.FileParser.init(allocator);
    errdefer parser.deinit();

    try parser.addFile(allocator, name, .{});
    try parser.writeFile(name);

    return parser;
}

test "operandFromByte decodes scalar arguments" {
    try testing.expectEqual(TypeId.i64, argumentFromByte(0x1A).?.val.typ);
    try testing.expectEqual(args.ArgSlot.arg1, argumentFromByte(0x1A).?.arg_num);
    try testing.expectEqual(args.ArgSlot.arg6, argumentFromByte(0x6A).?.arg_num);
    try testing.expect(argumentFromByte(0x00) == null);

    switch (operandFromByte(0x2A)) {
        .argument => |argument| try testing.expectEqual(args.ArgSlot.arg2, argument.arg_num),
        .literal => try testing.expect(false),
    }
    switch (operandFromByte(0x07)) {
        .argument => try testing.expect(false),
        .literal => |val| try testing.expectEqual(@as(u64, 7), val),
    }
}

test "test gen_func_body pushes an argument register" {
    const allocator = testing.allocator;
    const name = "gen_func_body_arg_push.afton";
    defer fs_compat.deleteFile(name) catch {};

    const program = [_]u8{ @intFromEnum(opcodes.Opcode.push), @intFromEnum(args.ArgSlot.arg1), @intFromEnum(opcodes.Opcode.end) };
    var parser = try loadModule(allocator, name, &program);
    defer parser.deinit();

    var ct = try CallTable.init(allocator);
    defer ct.deinit();

    try gen_func_body(&parser, &ct);

    const module = parser.program.getPtr(name).?;
    try testing.expectEqualSlices(u8, &[_]u8{ 0x41, 0x50 }, module.machcode.buffer[0..module.machcode.ip]);
}

test "test gen_func records the argument count" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const name = "gen_func_args.afton";
    defer fs_compat.deleteFile(name) catch {};

    const program = [_]u8{ @intFromEnum(opcodes.Opcode.fn_decl), 1, 'f', 0, 0, 2, @intFromEnum(opcodes.Opcode.ret), @intFromEnum(opcodes.RetExtension.void), @intFromEnum(opcodes.Opcode.end) };
    var parser = try loadModule(allocator, name, &program);
    defer parser.deinit();

    var ct = try CallTable.init(allocator);
    defer ct.deinit();

    try gen_func(&parser, &ct);

    try testing.expectEqual(@as(?usize, 2), ct.getArgCount("f"));
}

test "test gen_func_body on happy path" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fileParser = try pf.FileParser.init(allocator);
    defer fileParser.deinit();
    var ct = try CallTable.init(allocator);
    defer ct.deinit();

    const name: []u8 = try allocator.dupe(u8, "test.afton");
    defer allocator.free(name);

    try fs_compat.writeFileAll(name, &[_]u8{ @intFromEnum(opcodes.Opcode.dup), @intFromEnum(opcodes.Opcode.push), 0, @intFromEnum(opcodes.Opcode.rem), @intFromEnum(opcodes.Opcode.end) });
    defer fs_compat.deleteFile(name) catch {};
    try fileParser.addFile(allocator, name, .{});
    try fileParser.writeFile(name);
    try gen_func_body(&fileParser, &ct);

    const mc = try fileParser.readMachcode(name, 0, 17);

    defer allocator.free(mc);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x45, 0x8B, 0x44, 0x24, 0x49, 0x48, 0xB8, 0x08, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x48, 0x50 }, mc);
}

test "test gen_func_body emits ret operand" {
    const Case = struct {
        name: []const u8,
        operand: u8,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{ .name = "ret_void.afton", .operand = @intFromEnum(opcodes.RetExtension.void), .expected = &[_]u8{ 0xB8, 0x00, 0x00, 0x00, 0x00, 0xC9, 0xC3 } },
        .{ .name = "ret_stack.afton", .operand = @intFromEnum(opcodes.RetExtension.stack), .expected = &[_]u8{ 0x58, 0xC9, 0xC3 } },
        .{ .name = "ret_value.afton", .operand = 0x2A, .expected = &[_]u8{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC9, 0xC3 } },
    };

    for (cases) |case| {
        const allocator = testing.allocator;
        defer fs_compat.deleteFile(case.name) catch {};

        const program = [_]u8{ @intFromEnum(opcodes.Opcode.ret), case.operand, @intFromEnum(opcodes.Opcode.end) };
        var parser = try loadModule(allocator, case.name, &program);
        defer parser.deinit();

        var ct = try CallTable.init(allocator);
        defer ct.deinit();

        try gen_func_body(&parser, &ct);

        const module = parser.program.getPtr(case.name).?;
        try testing.expectEqualSlices(u8, case.expected, module.machcode.buffer[0..module.machcode.ip]);
    }
}

test "test gen_func" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fileParser = try pf.FileParser.init(allocator);
    defer fileParser.deinit();
    var ct = try CallTable.init(allocator);
    defer ct.deinit();

    const name: []u8 = try allocator.dupe(u8, "test.afton");
    defer allocator.free(name);

    const program = [_]u8{@intFromEnum(opcodes.Opcode.fn_decl)} ++ [_]u8{5} ++ [_]u8{ 't', 'e', 's', 't', 'A' } ++ [_]u8{ 0, 0, 0, @intFromEnum(opcodes.Opcode.rem), @intFromEnum(opcodes.Opcode.dup), @intFromEnum(opcodes.Opcode.end) };
    try fs_compat.writeFileAll(name, &program);
    defer fs_compat.deleteFile(name) catch {};

    try fileParser.addFile(allocator, name, .{});
    try fileParser.writeFile(name);

    try gen_func(&fileParser, &ct);

    try testing.expect(ct.cur_index == 1);
    if (ct.indexMap.get("testA")) |val| {
        try testing.expect(val == 0);
    }
    try testing.expect(ct.size == standardCTsize);
    try testing.expect(ct.callTable[0] > 1);
}

test "test gen_module generates a single function" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const name = "gen_module_single.afton";
    defer fs_compat.deleteFile(name) catch {};

    const program = [_]u8{ 0x02, 0xAF } ++
        [_]u8{ @intFromEnum(opcodes.Opcode.fn_decl), 3, 'f', 'o', 'o', 0, 0, 0 } ++
        [_]u8{ @intFromEnum(opcodes.Opcode.push), 0x2A } ++
        [_]u8{ @intFromEnum(opcodes.Opcode.ret), 0xFF } ++
        [_]u8{@intFromEnum(opcodes.Opcode.end)} ++
        [_]u8{@intFromEnum(opcodes.Opcode.end_prg)};

    var parser = try loadModule(allocator, name, &program);
    defer parser.deinit();

    var ct = try CallTable.init(allocator);
    defer ct.deinit();

    try gen_module(&parser, &ct);

    try testing.expectEqual(@as(usize, 1), ct.cur_index);
    try testing.expectEqual(@as(usize, 0), ct.indexMap.get("foo").?);
    try testing.expect(ct.callTable[0] != 0);

    const module = parser.program.getPtr(name).?;
    try testing.expectEqual(program.len, module.emit.ip);
    try testing.expect(module.machcode.ip > 0);
}

test "test gen_module generates several functions" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const name = "gen_module_multiple.afton";
    defer fs_compat.deleteFile(name) catch {};

    const fn_a = [_]u8{ @intFromEnum(opcodes.Opcode.fn_decl), 1, 'a', 0, 0, 0, @intFromEnum(opcodes.Opcode.ret), 0xFF, @intFromEnum(opcodes.Opcode.end) };
    const fn_b = [_]u8{ @intFromEnum(opcodes.Opcode.fn_decl), 1, 'b', 0, 0, 0, @intFromEnum(opcodes.Opcode.ret), 0xFF, @intFromEnum(opcodes.Opcode.end) };
    const program = [_]u8{ 0x02, 0xAF } ++ fn_a ++ fn_b ++ [_]u8{@intFromEnum(opcodes.Opcode.end_prg)};

    var parser = try loadModule(allocator, name, &program);
    defer parser.deinit();

    var ct = try CallTable.init(allocator);
    defer ct.deinit();

    try gen_module(&parser, &ct);

    try testing.expectEqual(@as(usize, 2), ct.cur_index);
    try testing.expectEqual(@as(usize, 0), ct.indexMap.get("a").?);
    try testing.expectEqual(@as(usize, 1), ct.indexMap.get("b").?);
    try testing.expect(ct.callTable[0] != 0);
    try testing.expect(ct.callTable[1] != 0);
}

test "test gen_module generates top-level instructions" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const name = "gen_module_toplevel.afton";
    defer fs_compat.deleteFile(name) catch {};

    const program = [_]u8{ 0x02, 0xAF } ++
        [_]u8{ @intFromEnum(opcodes.Opcode.push), 7 } ++
        [_]u8{@intFromEnum(opcodes.Opcode.end_prg)};

    var parser = try loadModule(allocator, name, &program);
    defer parser.deinit();

    var ct = try CallTable.init(allocator);
    defer ct.deinit();

    try gen_module(&parser, &ct);

    try testing.expectEqual(@as(usize, 0), ct.cur_index);

    const module = parser.program.getPtr(name).?;
    try testing.expectEqual(program.len, module.emit.ip);
    try testing.expect(module.machcode.ip > 0);
}

test "test gen_module generates invoke" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const name = "gen_module_invoke.afton";
    defer fs_compat.deleteFile(name) catch {};

    const fn_foo = [_]u8{ @intFromEnum(opcodes.Opcode.fn_decl), 3, 'f', 'o', 'o', 0, 0, 0, @intFromEnum(opcodes.Opcode.push), 0x2A, @intFromEnum(opcodes.Opcode.ret), 0xFF, @intFromEnum(opcodes.Opcode.end) };
    const fn_main = [_]u8{ @intFromEnum(opcodes.Opcode.fn_decl), 4, 'm', 'a', 'i', 'n', 0, 0, 0, @intFromEnum(opcodes.Opcode.invoke), 3, 'f', 'o', 'o', 0, @intFromEnum(opcodes.Opcode.ret), 0xFF, @intFromEnum(opcodes.Opcode.end) };
    const program = [_]u8{ 0x02, 0xAF } ++ fn_foo ++ fn_main ++ [_]u8{@intFromEnum(opcodes.Opcode.end_prg)};

    var parser = try loadModule(allocator, name, &program);
    defer parser.deinit();

    var ct = try CallTable.init(allocator);
    defer ct.deinit();

    try gen_module(&parser, &ct);

    try testing.expectEqual(@as(usize, 2), ct.cur_index);
    try testing.expectEqual(@as(usize, 0), ct.indexMap.get("foo").?);
    try testing.expectEqual(@as(usize, 1), ct.indexMap.get("main").?);

    const module = parser.program.getPtr(name).?;
    const call_table_base = @intFromPtr(ct.callTable.ptr);
    var expected = [_]u8{ 0x49, 0xBB, 0, 0, 0, 0, 0, 0, 0, 0, 0x48, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0x41, 0xFF, 0x14, 0xC3 };
    for (0..8) |i| {
        expected[2 + i] = @truncate(call_table_base >> @as(u6, @intCast(8 * i)));
    }

    try testing.expect(std.mem.indexOf(u8, module.machcode.buffer[0..module.machcode.ip], &expected) != null);
}

test "test gen_module rejects invoke of unknown function" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const name = "gen_module_unknown_invoke.afton";
    defer fs_compat.deleteFile(name) catch {};

    const fn_main = [_]u8{ @intFromEnum(opcodes.Opcode.fn_decl), 4, 'm', 'a', 'i', 'n', 0, 0, 0, @intFromEnum(opcodes.Opcode.invoke), 7, 'm', 'i', 's', 's', 'i', 'n', 'g', 0, @intFromEnum(opcodes.Opcode.ret), 0xFF, @intFromEnum(opcodes.Opcode.end) };
    const program = [_]u8{ 0x02, 0xAF } ++ fn_main ++ [_]u8{@intFromEnum(opcodes.Opcode.end_prg)};

    var parser = try loadModule(allocator, name, &program);
    defer parser.deinit();

    var ct = try CallTable.init(allocator);
    defer ct.deinit();

    try testing.expectError(error.UnknownFunction, gen_module(&parser, &ct));
}

test "test gen_module rejects unsupported version" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const name = "gen_module_bad_version.afton";
    defer fs_compat.deleteFile(name) catch {};

    const program = [_]u8{ 0x03, 0xAF, 0xFE };

    var parser = try loadModule(allocator, name, &program);
    defer parser.deinit();

    var ct = try CallTable.init(allocator);
    defer ct.deinit();

    try testing.expectError(error.UnsupportedVersion, gen_module(&parser, &ct));
}

test "test gen_module rejects bad magic" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const name = "gen_module_bad_magic.afton";
    defer fs_compat.deleteFile(name) catch {};

    const program = [_]u8{ 0x02, 0x00, 0xFE };

    var parser = try loadModule(allocator, name, &program);
    defer parser.deinit();

    var ct = try CallTable.init(allocator);
    defer ct.deinit();

    try testing.expectError(error.BadMagic, gen_module(&parser, &ct));
}

test "test gen_func rejects a non-function header" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const name = "gen_func_bad_header.afton";
    defer fs_compat.deleteFile(name) catch {};

    const program = [_]u8{ @intFromEnum(opcodes.Opcode.push), 1 };

    var parser = try loadModule(allocator, name, &program);
    defer parser.deinit();

    var ct = try CallTable.init(allocator);
    defer ct.deinit();

    try testing.expectError(error.ExpectedFnDecl, gen_func(&parser, &ct));
}

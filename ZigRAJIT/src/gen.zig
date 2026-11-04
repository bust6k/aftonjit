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

///Field is one flat scalar field of an aggregate argument.
pub const Field = struct {
    typ: TypeId,

    pub fn abi(self: Field) asmx64.AbiField {
        return .{
            .class = if (isFloatType(self.typ)) .ymm else .gpr,
            .size = typeSize(self.typ),
        };
    }
};

///Aggregate is a flat Afton ABI aggregate (struct/union/array-of-scalars).
pub const Aggregate = struct {
    size: usize,
    fields: []const Field,
};

pub fn isFloatType(typ: TypeId) bool {
    return typ == .f32 or typ == .f64;
}

pub fn typeSize(typ: TypeId) u8 {
    return switch (typ) {
        .void => 0,
        .i8, .u8, .bool => 1,
        .i16, .u16 => 2,
        .i32, .u32, .f32 => 4,
        .i64, .u64, .f64, .pointer => 8,
        .aggregate => 0,
    };
}

fn scalarClass(typ: TypeId) !asmx64.ScalarClass {
    if (isFloatType(typ)) return .ymm;
    return switch (typ) {
        .void, .aggregate => error.UnsupportedArgumentType,
        else => .gpr,
    };
}

const Value = struct {
    typ: TypeId,
    data: [32]u8,
    aggregate: ?Aggregate = null,
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

    ///aggregate builds an aggregate argument from its flat field list.
    pub fn aggregate(arg_num: args.ArgSlot, aggregate_value: Aggregate) Argument {
        return Argument{
            .arg_num = arg_num,
            .val = .{
                .typ = .aggregate,
                .data = std.mem.zeroes([32]u8),
                .aggregate = aggregate_value,
            },
        };
    }

    ///isFloat reports whether the argument belongs to a YMM register class.
    pub fn isFloat(self: Argument) bool {
        return isFloatType(self.val.typ);
    }

    ///isAggregate reports whether the argument is a struct-like value.
    pub fn isAggregate(self: Argument) bool {
        return self.val.typ == .aggregate;
    }

    pub fn param(self: Argument) Param {
        return .{
            .typ = self.val.typ,
            .aggregate_value = self.val.aggregate,
        };
    }
};

///Param is the type of one function parameter.
pub const Param = struct {
    typ: TypeId = .i64,
    aggregate_value: ?Aggregate = null,

    pub fn scalar(typ: TypeId) Param {
        return .{ .typ = typ };
    }

    pub fn aggregate(value: Aggregate) Param {
        return .{ .typ = .aggregate, .aggregate_value = value };
    }

    pub fn fromArgument(argument: Argument) Param {
        return argument.param();
    }
};

///Signature is a typed Afton function signature.
pub const Signature = struct {
    params: []const Param = &.{},
    ret: TypeId = .void,
    hidden: asmx64.HiddenArgs = .{},
};

///Operand is the high-level representation of a value consumed by an
///instruction: either a compile-time literal or a positional function argument.
pub const Operand = union(enum) {
    literal: u64,
    argument: Argument,
};

///argumentFromByte decodes ARG1..ARG6 placeholders into a scalar Argument.
pub fn argumentFromByte(byte: u8) ?Argument {
    const slot = std.enums.fromInt(args.ArgSlot, byte) orelse return null;
    return Argument.scalar(slot, .i64);
}

///operandFromByte decodes a byte operand into a literal or an argument.
pub fn operandFromByte(byte: u8) Operand {
    if (argumentFromByte(byte)) |argument| {
        return .{ .argument = argument };
    }
    return .{ .literal = byte };
}

fn buildArgMap(sig: Signature) !asmx64.ArgMap {
    var specs: [asmx64.MaxMappedArgs]asmx64.AbiArgType = undefined;
    var field_buffers: [asmx64.MaxMappedArgs][asmx64.MaxAggregateFields]asmx64.AbiField = undefined;

    if (sig.params.len > asmx64.MaxMappedArgs) return error.ErrorTooManyArguments;

    for (sig.params, 0..) |param, i| {
        if (param.aggregate_value) |aggregate_value| {
            if (aggregate_value.fields.len > asmx64.MaxAggregateFields) {
                return error.ErrorTooManyAggregateFields;
            }
            for (aggregate_value.fields, 0..) |field, j| {
                field_buffers[i][j] = field.abi();
            }
            specs[i] = .{ .aggregate = .{
                .size = aggregate_value.size,
                .fields = field_buffers[i][0..aggregate_value.fields.len],
            } };
        } else {
            specs[i] = .{ .scalar = try scalarClass(param.typ) };
        }
    }

    return asmx64.mapSignature(specs[0..sig.params.len], sig.hidden);
}

fn signatureYmmMask(sig: Signature) u16 {
    const map = buildArgMap(sig) catch return 0;
    var mask: u16 = 0;

    for (map.regs[0..map.reg_count]) |value| switch (value) {
        .gpr => {},
        .ymm => |reg| {
            const number = @intFromEnum(reg) - @intFromEnum(asmx64.Register.ymm6);
            if (number >= 0 and number < 10) {
                mask |= @as(u16, 1) << @intCast(number);
            }
        },
    };

    return mask;
}

fn asmOperand(operand: Operand, ct: *CallTable) !asmx64.Operand {
    return switch (operand) {
        .literal => |val| .{ .imm = val },
        .argument => |argument| {
            if (argument.isAggregate()) return error.UnsupportedArgumentType;

            if (ct.current_signature) |sig| {
                const map = try buildArgMap(sig);
                const locations = map.locations(argIndex(argument.arg_num));
                if (locations.len == 1) {
                    return switch (locations[0]) {
                        .gpr => |reg| .{ .reg = reg },
                        .ymm => |reg| .{ .ymm = reg },
                    };
                }
                if (locations.len > 1) return error.UnsupportedArgumentType;
            }

            if (argument.isFloat()) return .{ .ymm = asmx64.ymmScalarArgRegister(argument.arg_num) };
            return .{ .reg = asmx64.gprArgRegister(argument.arg_num) };
        },
    };
}

fn argIndex(arg_num: args.ArgSlot) usize {
    return switch (arg_num) {
        .arg1 => 0,
        .arg2 => 1,
        .arg3 => 2,
        .arg4 => 3,
        .arg5 => 4,
        .arg6 => 5,
    };
}

fn pushArgument(emit: *em.Emitter, ct: *CallTable, argument: Argument) !void {
    if (ct.current_signature) |sig| {
        const map = try buildArgMap(sig);
        const locations = map.locations(argIndex(argument.arg_num));
        if (locations.len > 0) {
            try asmx64.instr_push_abi_arg(emit, locations);
            return;
        }
    }

    if (argument.isAggregate()) return error.UnsupportedArgumentType;
    if (argument.isFloat()) return asmx64.instr_push_float_arg(emit, argument.arg_num);
    try asmx64.instr_push_arg(emit, argument.arg_num);
}

fn returnArgument(emit: *em.Emitter, ct: *CallTable, argument: Argument) !void {
    if (ct.abi_frame) {
        const map = if (ct.current_signature) |sig| try buildArgMap(sig) else return error.UnsupportedArgumentType;
        const locations = map.locations(argIndex(argument.arg_num));
        if (locations.len > 0) {
            try asmx64.instr_ret_abi_values(emit, locations, ct.current_ymm_mask);
            return;
        }
        if (argument.isAggregate()) return error.UnsupportedArgumentType;
        if (argument.isFloat()) {
            try asmx64.instr_ret_abi_values(emit, &[_]asmx64.AbiValue{.{ .ymm = asmx64.ymmScalarArgRegister(argument.arg_num) }}, ct.current_ymm_mask);
        } else {
            try asmx64.instr_ret_abi_values(emit, &[_]asmx64.AbiValue{.{ .gpr = asmx64.gprArgRegister(argument.arg_num) }}, ct.current_ymm_mask);
        }
        return;
    }

    if (argument.isAggregate()) return error.UnsupportedArgumentType;
    if (argument.isFloat()) return error.UnsupportedArgumentType;
    try asmx64.instr_ret_arg(emit, argument.arg_num);
}


pub const CallTable = struct {
    indexMap: std.StringHashMap(usize),
    //argCounts stores how many scalar arguments each declared function accepts.
    argCounts: std.StringHashMap(usize),
    //signatures stores the typed signature of every declared function.
    signatures: std.StringHashMap(Signature),
    //current_signature is set while a function body is being generated.
    current_signature: ?Signature = null,
    //abi_frame tells the code generator that an ABI prologue has been emitted.
    abi_frame: bool = false,
    current_ymm_mask: u16 = 0,
    //cur_index consisting of last used index in callTable. It's necessary for performance
    cur_index: usize,
    size: usize,
    callTable: []usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !CallTable {
        return CallTable{
            .indexMap = std.StringHashMap(usize).init(allocator),
            .argCounts = std.StringHashMap(usize).init(allocator),
            .signatures = std.StringHashMap(Signature).init(allocator),
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

        var sig_it = self.signatures.iterator();
        while (sig_it.next()) |entry| {
            self.freeSignature(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.signatures.deinit();

        self.cur_index = 0;
        self.size = 0;
        self.allocator.free(self.callTable);
    }

    fn freeSignature(self: *CallTable, sig: Signature) void {
        for (sig.params) |param| {
            if (param.aggregate_value) |aggregate_value| {
                self.allocator.free(aggregate_value.fields);
            }
        }
        self.allocator.free(sig.params);
    }

    fn cloneSignature(self: *CallTable, sig: Signature) !Signature {
        const params = try self.allocator.alloc(Param, sig.params.len);
        errdefer self.allocator.free(params);

        var initialized: usize = 0;
        errdefer {
            for (params[0..initialized]) |param| {
                if (param.aggregate_value) |aggregate_value| {
                    self.allocator.free(aggregate_value.fields);
                }
            }
        }

        for (sig.params, 0..) |param, i| {
            params[i] = param;
            if (param.aggregate_value) |aggregate_value| {
                const fields = try self.allocator.dupe(Field, aggregate_value.fields);
                params[i].aggregate_value = .{
                    .size = aggregate_value.size,
                    .fields = fields,
                };
            }
            initialized += 1;
        }

        return .{
            .params = params,
            .ret = sig.ret,
            .hidden = sig.hidden,
        };
    }

    pub fn addSignature(self: *CallTable, key: []const u8, sig: Signature) !void {
        const owned = try self.cloneSignature(sig);
        errdefer self.freeSignature(owned);

        const key_cpy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_cpy);

        if (self.signatures.fetchRemove(key)) |old| {
            self.freeSignature(old.value);
            self.allocator.free(old.key);
        }

        try self.signatures.put(key_cpy, owned);
    }

    pub fn getSignature(self: *CallTable, key: []const u8) ?Signature {
        return self.signatures.get(key);
    }

    ///ensureSignature installs an all-integer default signature if the caller
    ///did not provide one explicitly.
    pub fn ensureSignature(self: *CallTable, key: []const u8, arg_count: usize) !void {
        if (self.signatures.contains(key)) return;

        const params = try self.allocator.alloc(Param, arg_count);
        for (params) |*param| param.* = Param.scalar(.i64);

        const sig = Signature{ .params = params };
        try self.addSignature(key, sig);

        // addSignature made its own copy; release the temporary one.
        self.allocator.free(params);
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
    try ct.ensureSignature(name, args_cnt);

    const signature = ct.getSignature(name).?;
    const saved_signature = ct.current_signature;
    const saved_abi_frame = ct.abi_frame;
    const saved_ymm_mask = ct.current_ymm_mask;
    defer {
        ct.current_signature = saved_signature;
        ct.abi_frame = saved_abi_frame;
        ct.current_ymm_mask = saved_ymm_mask;
    }

    ct.current_signature = signature;
    ct.abi_frame = true;
    ct.current_ymm_mask = signatureYmmMask(signature);

    const func_addr = @intFromPtr(&module.machcode.buffer[module.machcode.ip]);
    if (builtin.cpu.arch == .x86_64) {
        try asmx64.fun_prologue_abi(&module.machcode, local_cnt, ct.current_ymm_mask);
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
                    .argument => |argument| try pushArgument(&module.machcode, ct, argument),
                },
                .rem => try asmx64.instr_rem(&module.machcode),
                .add => try asmx64.instr_binop(
                    &module.machcode,
                    .add,
                    try asmOperand(operandFromByte(instr.operands[0]), ct),
                    try asmOperand(operandFromByte(instr.operands[1]), ct),
                ),
                .sub => try asmx64.instr_binop(
                    &module.machcode,
                    .sub,
                    try asmOperand(operandFromByte(instr.operands[0]), ct),
                    try asmOperand(operandFromByte(instr.operands[1]), ct),
                ),
                .mul => try asmx64.instr_binop(
                    &module.machcode,
                    .mul,
                    try asmOperand(operandFromByte(instr.operands[0]), ct),
                    try asmOperand(operandFromByte(instr.operands[1]), ct),
                ),
                .div => try asmx64.instr_binop(
                    &module.machcode,
                    .divide,
                    try asmOperand(operandFromByte(instr.operands[0]), ct),
                    try asmOperand(operandFromByte(instr.operands[1]), ct),
                ),
                .ret => {
                    const ret_value = instr.operands[0];
                    switch (ret_value) {
                        @intFromEnum(opcodes.RetExtension.void) => {
                            if (ct.abi_frame) {
                                try asmx64.instr_ret_abi(&module.machcode, .void, 0, ct.current_ymm_mask);
                            } else {
                                try asmx64.instr_ret(&module.machcode, .void, 0);
                            }
                        },
                        @intFromEnum(opcodes.RetExtension.stack) => {
                            if (ct.abi_frame) {
                                try asmx64.instr_ret_abi(&module.machcode, .stack, 0, ct.current_ymm_mask);
                            } else {
                                try asmx64.instr_ret(&module.machcode, .stack, 0);
                            }
                        },
                        else => {
                            if (argumentFromByte(ret_value)) |argument| {
                                try returnArgument(&module.machcode, ct, argument);
                            } else {
                                if (ct.abi_frame) {
                                    try asmx64.instr_ret_abi(&module.machcode, .val, ret_value, ct.current_ymm_mask);
                                } else {
                                    try asmx64.instr_ret(&module.machcode, .val, ret_value);
                                }
                            }
                        },
                    }
                },
                .invoke => {
                    const fn_name = decoder.nameFromOperands(instr.operands);
                    const fn_index = ct.indexMap.get(fn_name) orelse return error.UnknownFunction;
                    if (ct.getSignature(fn_name)) |callee_signature| {
                        var specs: [asmx64.MaxMappedArgs]asmx64.AbiArgType = undefined;
                        var field_buffers: [asmx64.MaxMappedArgs][asmx64.MaxAggregateFields]asmx64.AbiField = undefined;
                        for (callee_signature.params, 0..) |param, i| {
                            if (param.aggregate_value) |aggregate_value| {
                                for (aggregate_value.fields, 0..) |field, j| {
                                    field_buffers[i][j] = field.abi();
                                }
                                specs[i] = .{ .aggregate = .{
                                    .size = aggregate_value.size,
                                    .fields = field_buffers[i][0..aggregate_value.fields.len],
                                } };
                            } else {
                                specs[i] = .{ .scalar = try scalarClass(param.typ) };
                            }
                        }
                        try asmx64.instr_invoke_abi(
                            &module.machcode,
                            @intFromPtr(ct.callTable.ptr),
                            fn_index,
                            @sizeOf(usize),
                            specs[0..callee_signature.params.len],
                            callee_signature.hidden,
                        );
                    } else {
                        const arg_count = ct.getArgCount(fn_name) orelse 0;
                        try asmx64.instr_invoke_args(
                            &module.machcode,
                            @intFromPtr(ct.callTable.ptr),
                            fn_index,
                            @sizeOf(usize),
                            arg_count,
                        );
                    }
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
        .{ .name = "ret_value.afton", .operand = 0x2A, .expected = &[_]u8{ 0x4C, 0x89, 0xC8, 0xC9, 0xC3 } },
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

test "buildArgMap maps floats and aggregates per Afton ABI" {
    const fields = [_]Field{
        .{ .typ = .i32 },
        .{ .typ = .f32 },
        .{ .typ = .i64 },
    };
    const params = [_]Param{
        Param.scalar(.i64),
        Param.aggregate(.{ .size = 16, .fields = &fields }),
        Param.scalar(.f64),
    };
    const sig = Signature{ .params = &params, .ret = .i64 };
    const map = try buildArgMap(sig);

    try testing.expectEqual(asmx64.Register.r8, map.locations(0)[0].gpr);

    const aggregate_locations = map.locations(1);
    try testing.expectEqual(@as(usize, 3), aggregate_locations.len);
    try testing.expectEqual(asmx64.Register.r9, aggregate_locations[0].gpr);
    try testing.expectEqual(asmx64.Register.ymm6, aggregate_locations[1].ymm);
    try testing.expectEqual(asmx64.Register.r10, aggregate_locations[2].gpr);

    try testing.expectEqual(asmx64.Register.ymm0, map.locations(2)[0].ymm);
}

test "buildArgMap shifts only GPR counters for sret and env" {
    const params = [_]Param{
        Param.scalar(.f64),
        Param.scalar(.i64),
    };
    const sig = Signature{
        .params = &params,
        .ret = .void,
        .hidden = .{ .sret = true, .env = true },
    };
    const map = try buildArgMap(sig);

    try testing.expectEqual(asmx64.Register.ymm0, map.locations(0)[0].ymm);
    try testing.expectEqual(asmx64.Register.r10, map.locations(1)[0].gpr);
}

test "CallTable stores typed signatures" {
    const allocator = testing.allocator;
    var ct = try CallTable.init(allocator);
    defer ct.deinit();

    const fields = [_]Field{.{ .typ = .f32 }};
    const params = [_]Param{
        Param.scalar(.i32),
        Param.aggregate(.{ .size = 4, .fields = &fields }),
    };
    try ct.addSignature("typed", .{ .params = &params, .ret = .f64 });

    const sig = ct.getSignature("typed").?;
    try testing.expectEqual(@as(usize, 2), sig.params.len);
    try testing.expectEqual(TypeId.i32, sig.params[0].typ);
    try testing.expectEqual(TypeId.f64, sig.ret);
    try testing.expectEqual(TypeId.f32, sig.params[1].aggregate_value.?.fields[0].typ);

    try ct.ensureSignature("default", 2);
    const default_sig = ct.getSignature("default").?;
    try testing.expectEqual(@as(usize, 2), default_sig.params.len);
    try testing.expectEqual(TypeId.i64, default_sig.params[0].typ);
}

test "typed argument push emits float and aggregate fields" {
    const allocator = testing.allocator;
    const name = "gen_typed_push.afton";
    defer fs_compat.deleteFile(name) catch {};

    const program = [_]u8{
        @intFromEnum(opcodes.Opcode.push), @intFromEnum(args.ArgSlot.arg1),
        @intFromEnum(opcodes.Opcode.push), @intFromEnum(args.ArgSlot.arg2),
        @intFromEnum(opcodes.Opcode.push), @intFromEnum(args.ArgSlot.arg3),
        @intFromEnum(opcodes.Opcode.end),
    };
    var parser = try loadModule(allocator, name, &program);
    defer parser.deinit();

    var ct = try CallTable.init(testing.allocator);
    defer ct.deinit();

    const fields = [_]Field{
        .{ .typ = .i64 },
        .{ .typ = .f32 },
        .{ .typ = .i64 },
    };
    const params = [_]Param{
        Param.scalar(.i64),
        Param.scalar(.f64),
        Param.aggregate(.{ .size = 20, .fields = &fields }),
    };
    try ct.addSignature("f", .{ .params = &params });
    ct.current_signature = ct.getSignature("f");

    try gen_func_body(&parser, &ct);

    const module = parser.program.getPtr(name).?;
    try testing.expectEqualSlices(u8, &[_]u8{
        0x41, 0x50, // push r8 (arg1)
        0x66, 0x48, 0x0F, 0x7E, 0xC0, 0x50, // push ymm0 (arg2)
        0x41, 0x51, // push r9 (aggregate field a)
        0x66, 0x48, 0x0F, 0x7E, 0xC6, 0x50, // push ymm6 (aggregate field b)
        0x41, 0x52, // push r10 (aggregate field c)
    }, module.machcode.buffer[0..module.machcode.ip]);
}

test "gen_func spills aggregate float registers and uses an ABI frame" {
    const allocator = testing.allocator;
    const name = "gen_func_aggregate.afton";
    defer fs_compat.deleteFile(name) catch {};

    const fields = [_]Field{.{ .typ = .f32 }};
    const params = [_]Param{
        Param.aggregate(.{ .size = 4, .fields = &fields }),
    };
    const program = [_]u8{
        @intFromEnum(opcodes.Opcode.fn_decl), 1, 'f', 0, 0, 1,
        @intFromEnum(opcodes.Opcode.ret), @intFromEnum(opcodes.RetExtension.void),
        @intFromEnum(opcodes.Opcode.end),
    };
    var parser = try loadModule(allocator, name, &program);
    defer parser.deinit();

    var ct = try CallTable.init(testing.allocator);
    defer ct.deinit();
    try ct.addSignature("f", .{ .params = &params });

    try gen_func(&parser, &ct);

    const module = parser.program.getPtr(name).?;
    // GPR spills end at offset 36; the next instruction spills YMM6.
    try testing.expectEqualSlices(u8, &[_]u8{
        0x66, 0x40, 0x0F, 0x11, 0xB5, 0xE0, 0xFF, 0xFF, 0xFF,
    }, module.machcode.buffer[36..45]);
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

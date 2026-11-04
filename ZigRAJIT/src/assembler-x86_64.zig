const std = @import("std");
const em = @import("emitter.zig"); 
const log = @import("logger.zig");
const retExtensions = @import("enum/opcodes.zig");
const opcodes = @import("enum/opcodes.zig");
const arguments = @import("enum/arguments.zig");
const pf = @import("parse_file.zig");
const testing = std.testing;
const builtin = @import("builtin");

pub const Register = enum(u8) {
    rax = 0,
    rcx = 1,
    rdx = 2,
    rbx = 3,
    rsp = 4,
    rbp = 5,
    rsi = 6,
    rdi = 7,
    r8 = 8,
    r9 = 9,
    r10 = 10,
    r11 = 11,
    r12 = 12,
    r13 = 13,
    r14 = 14,
    r15 = 15,
    eax = 16,
    ecx = 17,
    edx = 18,
    ebx = 19,
    esp = 20,
    ebp = 21,
    esi = 22,
    edi = 23,
};

/// Operand is a low-level representation of a value that an instruction can
/// consume. Scalars arrive either as compile-time immediates or as arguments
/// already placed in their ABI registers by the caller.
pub const Operand = union(enum) {
    imm: u64,
    reg: Register,
};

pub const BinOp = enum {
    add,
    sub,
    mul,
    divide,
};

const AssemblerX86_64Error = enum(u8) {
    ErrorDivideByNull,
    ErrorTooManyLocals,
    ErrorUnsupportedOs,
    VirtualProtectFailed,
    MprotectFailed,
    ErrorUnknownType,
    InvalidProtection,
};

var E: em.Emitter = undefined;

fn init() !void {
    var gpa = std.heap.DebugAllocator(.{}){};

    const allocator = gpa.allocator();

    E = try em.init(allocator, em.standardEmSize);
}

/// returns the string format of OS name that AftonJIT would to support
///
/// error ErrorUnsupportedOs occured if AftonJIT not working with current os
fn getOsName(os: builtin.target.os.tag) ![]u8 {
    switch (os) {
        .linux => {
            return "Linux";
        },
        .macos => {
            return "MacOS";
        },
        .windows => {
            return "Windows";
        },
        else => {
            return error.ErrorUnsupportedOs;
        },
    }
}

const linuxProtHasDecls = @hasDecl(std.os.linux.PROT, "READ");
const LinuxProt = if (linuxProtHasDecls) usize else std.os.linux.PROT;

fn linuxProt(protection: usize) !LinuxProt {
    if (comptime linuxProtHasDecls) {
        return switch (protection) {
            1 => std.os.linux.PROT.READ,
            2 => std.os.linux.PROT.WRITE,
            3 => std.os.linux.PROT.READ | std.os.linux.PROT.WRITE,
            4 => std.os.linux.PROT.EXEC,
            5 => std.os.linux.PROT.READ | std.os.linux.PROT.EXEC,
            6 => std.os.linux.PROT.WRITE | std.os.linux.PROT.EXEC,
            7 => std.os.linux.PROT.READ | std.os.linux.PROT.WRITE | std.os.linux.PROT.EXEC,
            else => return error.InvalidProtection,
        };
    } else {
        return switch (protection) {
            1 => .{ .READ = true },
            2 => .{ .WRITE = true },
            3 => .{ .READ = true, .WRITE = true },
            4 => .{ .EXEC = true },
            5 => .{ .READ = true, .EXEC = true },
            6 => .{ .WRITE = true, .EXEC = true },
            7 => .{ .READ = true, .WRITE = true, .EXEC = true },
            else => return error.InvalidProtection,
        };
    }
}

///the flexible wrapper bottom raw OS-syscalls
///
///API of changeMemoryRights same as of POSIX's mmap syscall
///
///internally,mapping protection values to correspond Windows-flags
///
///if current host OS is unsupported,retruns ErrorUnsupportedOs
pub fn changeMemoryRights(address: [*]u8, length: usize, protection: usize) !void {
    switch (builtin.target.os.tag) {
        .linux, .macos => {
            const prot = try linuxProt(protection);
            const rc = std.os.linux.mprotect(address, length, prot);
            if (rc < 0) return error.MprotectFailed;
        },
        .windows => {
            var oldFlags: u32 = 0;
            const win_prot = switch (protection) {
                1 => std.os.windows.PAGE_READONLY,
                2 => std.os.windows.PAGE_READWRITE,
                3 => std.os.windows.PAGE_EXECUTE_READ,
                4 => std.os.windows.PAGE_EXECUTE_READWRITE,
                5 => std.os.windows.PAGE_NOACCESS,
                else => return error.InvalidProtection,
            };
            const rc = std.os.windows.VirtualProtect(address, length, win_prot, &oldFlags);
            if (rc == 0) return error.VirtualProtectFailed;
        },
        else => return error.ErrorUnsupportedOs,
    }
}

fn castReg(reg: Register) u8 {
    return @intFromEnum(reg);
}

///movRegToReg emits a full 64-bit register-to-register move.
///
/// Unlike movRegs it emits the REX prefix required for r8-r15.
pub fn movRegToReg(emit: *em.Emitter, src: Register, dest: Register) !void {
    const src_reg = castReg(src);
    const dest_reg = castReg(dest);

    try rex(emit, 1, @intFromBool(src_reg >= 8), 0, @intFromBool(dest_reg >= 8));
    try emit.emit(0x89);
    try modrm(emit, 0b11, src_reg & 0b111, dest_reg & 0b111);
}

///loadOperand materializes an operand into dest.
fn loadOperand(emit: *em.Emitter, operand: Operand, dest: Register) !void {
    switch (operand) {
        .imm => |val| try movImm(emit, u64, dest, val),
        .reg => |reg| try movRegToReg(emit, reg, dest),
    }
}

///instr_binop performs a 64-bit binary operation on two operands and pushes the
///result onto the stack.
///
/// Operands may be immediates or scalar arguments already living in GPRs.
pub fn instr_binop(emit: *em.Emitter, op: BinOp, a: Operand, b: Operand) !void {
    switch (op) {
        .add => {
            try loadOperand(emit, a, Register.rax);
            try loadOperand(emit, b, Register.rcx);

            try rex(emit, 1, 0, 0, 0);
            try emit.emit(0x01);
            try modrm(emit, 0b11, castReg(Register.rcx), castReg(Register.rax));
        },
        .sub => {
            try loadOperand(emit, a, Register.rax);
            try loadOperand(emit, b, Register.rcx);

            try rex(emit, 1, 0, 0, 0);
            try emit.emit(0x29);
            try modrm(emit, 0b11, castReg(Register.rcx), castReg(Register.rax));
        },
        .mul => {
            try loadOperand(emit, a, Register.rax);
            try loadOperand(emit, b, Register.rcx);

            try rex(emit, 1, 0, 0, 0);
            try escape(emit);
            try emit.emit(0xAF);
            try modrm(emit, 0b11, castReg(Register.rax), castReg(Register.rcx));
        },
        .divide => {
            switch (b) {
                .imm => |val| if (val == 0) {
                    log.fatal("divide by 0 is forbidden", .{});
                    return error.ErrorDivideByNull;
                },
                .reg => {},
            }

            try loadOperand(emit, a, Register.rax);

            try rex(emit, 1, 0, 0, 0);
            try emit.emit(0x33);
            try modrm(emit, 0b11, castReg(Register.rdx), castReg(Register.rdx));

            try loadOperand(emit, b, Register.rbx);

            try rex(emit, 1, 0, 0, 0);
            try emit.emit(0xF7);
            try modrm(emit, 0b11, 0b110, castReg(Register.rbx));
        },
    }

    try pushReg64(emit, Register.rax);
}

///instr_add adds two  64-bit numbers or variables and puts calculated value  onto the stack
///
/// internally uses registers for store data  to operations or stack if all registers are busy
pub fn instr_add(emit: *em.Emitter, a: u64, b: u64) !void {
    try instr_binop(emit, .add, .{ .imm = a }, .{ .imm = b });
}

///instr_sub subs two  64-bit numbers or variables and puts calculated value onto the stack
///
/// internally uses registers for store data  to operations or stack if all registers are busy
pub fn instr_sub(emit: *em.Emitter, a: u64, b: u64) !void {
    try instr_binop(emit, .sub, .{ .imm = a }, .{ .imm = b });
}

///instr_mul multiplies two  64-bit numbers or variables and puts calculated value onto the stack
///
/// internally uses registers for store data  to operations or stack if all registers are busy
pub fn instr_mul(emit: *em.Emitter, a: u64, b: u64) !void {
    try instr_binop(emit, .mul, .{ .imm = a }, .{ .imm = b });
}

///instr_div divides  two  64-bit numbers or variables and puts calculated value onto the stack
///
/// internally uses registers for store data  to operations or stack if all registers are busy
///
/// when divider is zero,instr_div returns ErrorDivideByNull error
pub fn instr_div(emit: *em.Emitter, a: u64, b: u64) !void {
    try instr_binop(emit, .divide, .{ .imm = a }, .{ .imm = b });
}

///instr_ret exit from function  also returning value/variable/nothing
///
///when RetExtension set as void,instr_ret fill eax register by zeroes as means it return nothing
///
///when RetExtension set as stack,instr_ret puts the last stack value into eax register as means it returns from stack
///
///when RetExtension set as val,instr_ret puts the value/variable's value onto the stack
///
///internally,uses eax as store register
pub fn instr_ret(emit: *em.Emitter, ret_ex: retExtensions.RetExtension, ret_val: u16) !void {
    if (ret_ex == .void) {
        try movImm(emit, u32, Register.eax, 0x00000000);
        try emit.emit(0xC9);
        try emit.emit(0xC3);
    } else if (ret_ex == .stack) {
        try popReg(emit, Register.eax);
        try emit.emit(0xC9);
        try emit.emit(0xC3);
    } else {
        try movImm(emit, u16, Register.eax, ret_val);
        try emit.emit(0xC9);
        try emit.emit(0xC3);
    }
}

///gprArgRegister maps an Afton ABI scalar argument position to its GPR.
///
/// Afton ABI v1 places scalar integer/pointer arguments in R8..R13.
pub fn gprArgRegister(arg_num: arguments.ArgSlot) Register {
    return switch (arg_num) {
        .arg1 => .r8,
        .arg2 => .r9,
        .arg3 => .r10,
        .arg4 => .r11,
        .arg5 => .r12,
        .arg6 => .r13,
    };
}

///instr_push_arg pushes an integer/pointer scalar argument onto the stack.
pub fn instr_push_arg(emit: *em.Emitter, arg_num: arguments.ArgSlot) !void {
    try pushReg64(emit, gprArgRegister(arg_num));
}

///instr_ret_arg returns an integer/pointer scalar argument in RAX.
pub fn instr_ret_arg(emit: *em.Emitter, arg_num: arguments.ArgSlot) !void {
    try movRegToReg(emit, gprArgRegister(arg_num), Register.rax);
    try emit.emit(0xC9);
    try emit.emit(0xC3);
}

pub fn instr_push(emit: *em.Emitter, comptime T: type, val: T) !void {
    switch (@typeInfo(T)) {
        .int => {
            if (@sizeOf(T) <= 4) {
                try pushImm(emit, u32, val);
            } else {
                try pushImm(emit, u64, val);
            }
        },
        else => {
            log.fatal("push instruction supports int values only", .{});
            return error.ErrorUnknownType;
        },
    }
}

///instr_rem removes the last value from stack
pub inline fn instr_rem(emit: *em.Emitter) !void {
    try subImm(emit, u64, Register.rsp, 8);
}

///instr_invoke calls the function stored in the Call Table entry selected by SIB
///
///emits: call qword ptr [r11 + rax * scale]
///
///base  - address of the Call Table
///index - index of the function inside the Call Table
///scale - size of one Call Table element in bytes (1, 2, 4 or 8)
///
///x86 SIB computes the effective address as base + index * scale, so the
///register index is multiplied by scale to get the byte offset inside the table
pub fn instr_invoke(emit: *em.Emitter, base: usize, index: usize, scale: usize) !void {
    try instr_invoke_args(emit, base, index, scale, 0);
}

///instr_invoke_args is instr_invoke with scalar argument passing.
///
/// The caller pushes scalar arguments in declaration order (arg1 first). Before
/// the call they are popped in reverse order into the Afton ABI argument
/// registers R8..R13, so arg1 ends up in R8 and argN in R(8 + N - 1).
pub fn instr_invoke_args(emit: *em.Emitter, base: usize, index: usize, scale: usize, arg_count: usize) !void {
    if (arg_count > 6) {
        return error.ErrorTooManyArguments;
    }

    var arg: usize = arg_count;
    while (arg > 0) : (arg -= 1) {
        const slot: arguments.ArgSlot = @enumFromInt(@as(u8, @intCast(0x1A + (arg - 1) * 0x10)));
        try popReg64(emit, gprArgRegister(slot));
    }

    const scale_bits: u2 = switch (scale) {
        1 => 0,
        2 => 1,
        4 => 2,
        8 => 3,
        else => return error.InvalidSibScale,
    };

    
    try rex(emit, 1, 0, 0, 1);
    try emit.emit(0xBB);
    try emit.emitQuad(@intCast(base));

    
    try movImm(emit, u64, Register.rax, @intCast(index));

    
    try rex(emit, 0, 0, 0, 1); 
    try emit.emit(0xFF);
    try modrm(emit, 0b00, 0b010, 0b100); // /2, rm=100 means SIB follows
    try sib(emit, scale_bits, castReg(Register.rax) & 0b111, castReg(Register.r11) & 0b111);
}

///instr_dup copies the last value from stack
///
///internally,uses registers for store
pub fn instr_dup(emit: *em.Emitter) !void {
    try rex(emit, 0, 1, 0, 1);
    try movMemValToReg(emit, Register.r8, Register.rsp);
    try rex(emit, 1, 0, 0, 1);
    try pushImm(emit, u64, @intFromEnum(Register.r8));
}
//5 bytes + 3 = 8 bytes
///fun_prologue emits the standard function prologue for x86_64
///
///if locals count equals zero,no sub instruction generated
pub fn fun_prologue(emit: *em.Emitter, loc_count: u8) !void {
    try pushReg(emit, Register.rbp);
    try rex(emit, 1, 0, 0, 0);
    try movRegs(emit, Register.rsp, Register.rbp);

    if (loc_count != 0) {
        if (loc_count > 100) {
            log.fatal("arguments count at function cannot be greater than 100", .{});
            return error.ErrorTooManyLocals;
        }
        try rex(emit, 1, 0, 0, 0);
        try subImm(emit, u16, Register.rsp, loc_count * 8);
    }
}


///stub emits the stub byte stub_candidate of N times count
///returns start position of stub sequence
pub fn stub(emit: *em.Emitter, stub_candidate: u8, count: u16) !usize {
    const start_ip: usize = emit.ip;
    var i: u16 = 0;

    while (i <= count) : (i = i + 1) {
        try emit.emit(stub_candidate);
    }

    return start_ip;
}

pub inline fn fromSpecialToCommonRegister(regNumber: Register) u8 {
    switch (regNumber) {
        .r8 => return 0,
        .r9 => return 1,
        .r10 => return 2,
        .r11 => return 3,
        .r12 => return 4,
        .r13 => return 5,
        .r14 => return 6,
        .r15 => return 7,
        else => return castReg(regNumber),
    }
}

pub inline fn pushReg(emit: *em.Emitter, regNumber: Register) !void {
    if (isExtended(regNumber)) {
        try emit.emit(0x50 | fromSpecialToCommonRegister(regNumber));

        return;
    }

    try emit.emit(0x50 | castReg(regNumber));
}

///pushReg64 pushes a full 64-bit GPR, emitting REX.B for r8-r15.
pub fn pushReg64(emit: *em.Emitter, regNumber: Register) !void {
    const reg = castReg(regNumber);
    if (reg >= 8 and reg <= 15) {
        try rex(emit, 0, 0, 0, 1);
    }
    try emit.emit(0x50 | (reg & 0b111));
}

///popReg64 pops a full 64-bit GPR, emitting REX.B for r8-r15.
pub fn popReg64(emit: *em.Emitter, regNumber: Register) !void {
    const reg = castReg(regNumber);
    if (reg >= 8 and reg <= 15) {
        try rex(emit, 0, 0, 0, 1);
    }
    try emit.emit(0x58 | (reg & 0b111));
}

pub fn pushImm(emit: *em.Emitter, comptime T: type, val: T) !void {
    const size = @sizeOf(T);

    if (size <= 4) {
        try emit.emit(0x68);
        try emit.emitDWord(@as(u32, @intCast(val)));
    } else {
        try movImm(emit, u64, Register.rax, val);
        try rex(emit, 1, 0, 0, 0);
        try pushReg(emit, Register.rax);
    }
}

pub fn movImm(emit: *em.Emitter, comptime T: type, dest: Register, val: T) !void {
    const size = @sizeOf(T);

    if (size <= 4) {
        try emit.emit(0xB8 | castReg(dest));
        try emit.emitDWord(@as(u32, @intCast(val)));
    } else {
        if (isExtended(dest)) {
            try rex(emit, 1, 0, 0, 1);
            try emit.emit(0xB8 | castReg(dest));
            try emit.emitQuad(@as(u64, val));
            return;
        }

        try rex(emit, 1, 0, 0, 0);
        try emit.emit(0xB8 | castReg(dest));
        try emit.emitQuad(@as(u64, val));
    }
}

pub inline fn movMemValToReg(emit: *em.Emitter, reg: Register, base: Register) !void {
    try emit.emit(0x8B);
    try modrm(emit, 0x00, castReg(reg), 0b100);
    try sib(emit, 0, 0b100, castReg(base));
}

pub inline fn popReg(emit: *em.Emitter, regNumber: Register) !void {
    try emit.emit(0x58 | castReg(regNumber));
}

pub fn movRegs(emit: *em.Emitter, src: Register, dest: Register) !void {
    try emit.emit(0x89);
    try modrm(emit, 0x03, castReg(src), castReg(dest));
}

pub fn subImm(emit: *em.Emitter, comptime T: type, dest: Register, val: T) !void {
    const size = @sizeOf(@TypeOf(val));

    if (size <= 4) {
        if (isAccumulator(dest)) {
            try emit.emit(0x2D);
            try emit.emitDWord(@as(u32, val));
            return;
        }

        try emit.emit(0x81);
        try modrm(emit, 0x03, 0x05, castReg(dest));
        try emit.emitDWord(@as(u32, val));
    } else {
        if (isAccumulator(dest)) {
            try rex(emit, 1, 0, 0, 0);
            try emit.emit(0x2D);
            try emit.emitQuad(@as(u64, val));
            return;
        } else if (isExtended(dest)) {
            try movImm(emit, u64, Register.rcx, val);
            try rex(emit, 1, 0, 0, 1);
            try emit.emit(0x29);
            try modrm(emit, 0x03, castReg(Register.rcx), castReg(dest));
        }

        try movImm(emit, u64, Register.rcx, val);
        try rex(emit, 1, 0, 0, 0);
        try emit.emit(0x29);
        try modrm(emit, 0x03, castReg(Register.rcx), castReg(dest));
    }
}

inline fn nop(emit: *em.Emitter) !void {
    try emit.emit(0x90);
}

inline fn isExtended(reg: Register) bool {
    return castReg(reg) >= 8 and castReg(reg) <= 15;
}

inline fn isAccumulator(reg: Register) bool {
    return reg == .rax or reg == .eax;
}

pub fn rex(emit: *em.Emitter, w: u8, r: u8, x: u8, b: u8) !void {
    try emit.emit(0x40 | (w << 3) | (r << 2) | (x << 1) | b);
}

pub fn modrm(emit: *em.Emitter, mod: u8, reg: u8, rm: u8) !void {
    try emit.emit((mod << 6) | (reg << 3) | rm);
}

pub inline fn sib(emit: *em.Emitter, scale: u8, index: u8, base: u8) !void {
    try emit.emit((scale << 6) | (index << 3) | base);
}

pub inline fn escape(emit: *em.Emitter) !void {
    try emit.emit(0x0F);
}

test "instr_push" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try em.Emitter.init(allocator, 17);
    defer emitter.deinit();
    try instr_push(&emitter, u32, @as(u32, 10));

    try testing.expect(emitter.buffer[0] == 0x68);
    try testing.expect(emitter.buffer[1] == 0x0A);
    try testing.expect(emitter.buffer[2] == 0x00);
    try testing.expect(emitter.buffer[3] == 0x00);
    try testing.expect(emitter.buffer[4] == 0x00);

    try instr_push(&emitter, u64, @as(u64, 10));

    try testing.expect(emitter.buffer[5] == 0x48);
    try testing.expect(emitter.buffer[6] == 0xB8);
    try testing.expect(emitter.buffer[7] == 0x0A);

    try testing.expect(emitter.buffer[8] == 0x00);
    try testing.expect(emitter.buffer[9] == 0x00);
    try testing.expect(emitter.buffer[10] == 0x00);
    try testing.expect(emitter.buffer[11] == 0x00);
    try testing.expect(emitter.buffer[12] == 0x00);
    try testing.expect(emitter.buffer[13] == 0x00);
    try testing.expect(emitter.buffer[14] == 0x00);

    try testing.expect(emitter.buffer[15] == 0x48);
    try testing.expect(emitter.buffer[16] == 0x50);
}

test "instr_ret" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try em.Emitter.init(allocator, 700);
    defer emitter.deinit();

    try instr_ret(&emitter, retExtensions.RetExtension.void, 0);
    try testing.expect(emitter.buffer[0] == 0xB8);
    try testing.expect(emitter.buffer[1] == 0x00);
    try testing.expect(emitter.buffer[2] == 0x00);
    try testing.expect(emitter.buffer[3] == 0x00);
    try testing.expect(emitter.buffer[4] == 0x00);
    try testing.expect(emitter.buffer[5] == 0xC9);
    try testing.expect(emitter.buffer[6] == 0xC3);
    try instr_ret(&emitter, retExtensions.RetExtension.stack, 0);

    try testing.expect(emitter.buffer[7] == 0x58);
    try testing.expect(emitter.buffer[8] == 0xC9);
    try testing.expect(emitter.buffer[9] == 0xC3);

    try instr_ret(&emitter, retExtensions.RetExtension.val, @as(u16, 5));

    try testing.expect(emitter.buffer[10] == 0xB8);
    try testing.expect(emitter.buffer[11] == 0x05);
    try testing.expect(emitter.buffer[12] == 0x00);
    try testing.expect(emitter.buffer[13] == 0x00);
    try testing.expect(emitter.buffer[14] == 0x00);
    try testing.expect(emitter.buffer[15] == 0xC9);
    try testing.expect(emitter.buffer[16] == 0xC3);
}

test "instr_invoke" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try em.Emitter.init(allocator, 700);
    defer emitter.deinit();

    const base: usize = 0x1122334455667788;
    const index: usize = 0x2A;
    try instr_invoke(&emitter, base, index, @sizeOf(usize));

    try testing.expectEqual(@as(usize, 24), emitter.ip);
    try testing.expectEqualSlices(u8, &[_]u8{
        0x49, 0xBB,
        0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
        0x48, 0xB8,
        0x2A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x41, 0xFF, 0x14, 0xC3,
    }, emitter.buffer[0..emitter.ip]);
}

test "gprArgRegister maps scalar arguments to ABI registers" {
    try testing.expectEqual(Register.r8, gprArgRegister(.arg1));
    try testing.expectEqual(Register.r9, gprArgRegister(.arg2));
    try testing.expectEqual(Register.r10, gprArgRegister(.arg3));
    try testing.expectEqual(Register.r11, gprArgRegister(.arg4));
    try testing.expectEqual(Register.r12, gprArgRegister(.arg5));
    try testing.expectEqual(Register.r13, gprArgRegister(.arg6));
}

test "instr_push_arg pushes the argument ABI register" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try em.Emitter.init(allocator, 32);
    defer emitter.deinit();

    try instr_push_arg(&emitter, .arg1);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x41, 0x50 }, emitter.buffer[0..emitter.ip]);

    try instr_push_arg(&emitter, .arg6);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x41, 0x50, 0x41, 0x55 }, emitter.buffer[0..emitter.ip]);
}

test "instr_ret_arg returns the argument ABI register" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try em.Emitter.init(allocator, 32);
    defer emitter.deinit();

    try instr_ret_arg(&emitter, .arg1);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x4C, 0x89, 0xC0, 0xC9, 0xC3 }, emitter.buffer[0..emitter.ip]);
}

test "instr_invoke_args pops scalar arguments in reverse order" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try em.Emitter.init(allocator, 128);
    defer emitter.deinit();

    const base: usize = 0x1122334455667788;
    try instr_invoke_args(&emitter, base, 0x2A, @sizeOf(usize), 2);

    try testing.expectEqual(@as(usize, 28), emitter.ip);
    try testing.expectEqualSlices(u8, &[_]u8{
        0x41, 0x59, // pop r9  (arg2)
        0x41, 0x58, // pop r8  (arg1)
    }, emitter.buffer[0..4]);
}

test "scalar arguments flow through push, binop and ret" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try em.Emitter.init(allocator, 1024);
    defer emitter.deinit();

    const callee_off = emitter.ip;
    try fun_prologue(&emitter, 0);
    try instr_push_arg(&emitter, .arg1);
    try instr_push_arg(&emitter, .arg2);
    try instr_binop(&emitter, .add, .{ .reg = .r8 }, .{ .reg = .r9 });
    try instr_ret(&emitter, retExtensions.RetExtension.stack, 0);

    const callee_addr = @intFromPtr(emitter.buffer.ptr) + callee_off;
    const caller_off = emitter.ip;

    try movRegToReg(&emitter, .rdi, .r8);
    try movRegToReg(&emitter, .rsi, .r9);
    try movImm(&emitter, u64, .rax, callee_addr);
    try emitter.emit(0xFF);
    try modrm(&emitter, 0b11, 0b010, 0b000);
    try emitter.emit(0xC3);

    try changeMemoryRights(emitter.buffer.ptr, emitter.buffer.len, 5);
    defer changeMemoryRights(emitter.buffer.ptr, emitter.buffer.len, 3) catch {};

    const caller = @as(*const fn (u64, u64) callconv(.c) u64, @ptrFromInt(@intFromPtr(emitter.buffer.ptr) + caller_off));
    try testing.expectEqual(@as(u64, 12), caller(5, 7));
}

test "instr_div" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try em.Emitter.init(allocator, 4);

    defer emitter.deinit();

    try fun_prologue(&emitter, 0);
    try instr_div(&emitter, 10, 5);
    try emitter.emit(0xC9);
    try emitter.emit(0xC3);

    try changeMemoryRights(emitter.buffer.ptr, emitter.buffer.len, 5);

    const func = @as(*const fn () u64, @ptrCast(emitter.buffer.ptr));

    const res: u64 = func();

    try testing.expect(res == 2);
    try changeMemoryRights(emitter.buffer.ptr, emitter.buffer.len, 3);
}

//TODO: that function work incorrect. fix div and them too
test "instr_mul" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try em.Emitter.init(allocator, 4);
    defer emitter.deinit();

    try fun_prologue(&emitter, 0);
    try instr_mul(&emitter, 5, 4);
    try emitter.emit(0xC9);
    try emitter.emit(0xC3);

    try changeMemoryRights(emitter.buffer.ptr, emitter.buffer.len, 5);

    const func = @as(*const fn () u64, @ptrCast(emitter.buffer.ptr));

    const res: u64 = func();

    try testing.expect(res == 20);
    try changeMemoryRights(emitter.buffer.ptr, emitter.buffer.len, 3);
}

test "instr_sub" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try em.Emitter.init(allocator, 4);
    defer emitter.deinit();

    try fun_prologue(&emitter, 0);
    try instr_sub(&emitter, 5, 4);
    try emitter.emit(0xC9);
    try emitter.emit(0xC3);

    try changeMemoryRights(emitter.buffer.ptr, emitter.buffer.len, 5);

    const func = @as(*const fn () u64, @ptrCast(emitter.buffer.ptr));

    const res = func();
    try changeMemoryRights(emitter.buffer.ptr, emitter.buffer.len, 3);

    try testing.expect(res == 1);
    try changeMemoryRights(emitter.buffer.ptr, emitter.buffer.len, 3);
}

test "instr_add" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try em.Emitter.init(allocator, 4);
    defer emitter.deinit();

    try fun_prologue(&emitter, 1);
    try instr_add(&emitter, 5, 4);
    try emitter.emit(0xC9);
    try emitter.emit(0xC3);

    try changeMemoryRights(emitter.buffer.ptr, emitter.buffer.len, 5);

    const func = @as(*const fn () u64, @ptrCast(emitter.buffer.ptr));

    const res = func();
    try changeMemoryRights(emitter.buffer.ptr, emitter.buffer.len, 3);

    try testing.expect(res == 9);
    try changeMemoryRights(emitter.buffer.ptr, emitter.buffer.len, 3);
}

test "pushReg" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var emitter = try em.Emitter.init(gpa.allocator(), 16);
    defer emitter.deinit();

    try fun_prologue(&emitter, 0);
    try pushReg(&emitter, Register.rax);
    try testing.expect(emitter.buffer[4] == 0x50);

    try pushReg(&emitter, Register.r8);

    try testing.expect(emitter.buffer[5] == 0x50);
    try emitter.emit(0xC9);
    try emitter.emit(0xC3);
}

test "pushImm" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var emitter = try em.Emitter.init(gpa.allocator(), 32);
    defer emitter.deinit();

    try fun_prologue(&emitter, 0);
    try pushImm(&emitter, u32, 0x12345678);
    try testing.expect(emitter.buffer[4] == 0x68);
    try testing.expect(emitter.buffer[5] == 0x78);
    try testing.expect(emitter.buffer[6] == 0x56);
    try testing.expect(emitter.buffer[7] == 0x34);
    try testing.expect(emitter.buffer[8] == 0x12);
}

test "movImm" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var emitter = try em.Emitter.init(gpa.allocator(), 32);
    defer emitter.deinit();

    try fun_prologue(&emitter, 0);
    try movImm(&emitter, u32, Register.rax, 0x12345678);
    try testing.expect(emitter.buffer[4] == 0xB8 | 0);
    try testing.expect(emitter.buffer[5] == 0x78);
    try testing.expect(emitter.buffer[6] == 0x56);
    try testing.expect(emitter.buffer[7] == 0x34);
    try testing.expect(emitter.buffer[8] == 0x12);
}

test "movMemValToReg" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var emitter = try em.Emitter.init(gpa.allocator(), 16);
    defer emitter.deinit();

    try fun_prologue(&emitter, 0);
    try movMemValToReg(&emitter, Register.rax, Register.rsp);
    try testing.expect(emitter.buffer[4] == 0x8B);
    try testing.expect(emitter.buffer[5] == 0x04);
    try testing.expect(emitter.buffer[6] == 0x24);
}

test "popReg" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var emitter = try em.Emitter.init(gpa.allocator(), 16);
    defer emitter.deinit();

    try fun_prologue(&emitter, 0);
    try popReg(&emitter, Register.rax);
    try testing.expect(emitter.buffer[4] == 0x58);

    try popReg(&emitter, Register.r8);
    try testing.expect(emitter.buffer[5] == 0x58 | 0);
}

test "movRegs" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var emitter = try em.Emitter.init(gpa.allocator(), 16);
    defer emitter.deinit();

    try fun_prologue(&emitter, 0);
    try movRegs(&emitter, Register.rax, Register.rbx);
    try testing.expect(emitter.buffer[4] == 0x89);
    try testing.expect(emitter.buffer[5] == 0xC0 | (0 << 3) | 3);
}

test "subImm" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try em.Emitter.init(allocator, 4);
    defer emitter.deinit();

    try movImm(&emitter, u8, Register.rax, 120);
    try subImm(&emitter, u8, Register.rax, 2);
    try emitter.emit(0xC3);

    try changeMemoryRights(emitter.buffer.ptr, emitter.buffer.len, 5);

    const func = @as(*const fn () u64, @ptrCast(emitter.buffer.ptr));

    const res = func();
    try changeMemoryRights(emitter.buffer.ptr, emitter.buffer.len, 3);

    try testing.expect(res == 118);
    try changeMemoryRights(emitter.buffer.ptr, emitter.buffer.len, 3);
}

test "nop" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try em.Emitter.init(allocator, 4);
    defer emitter.deinit();

    try nop(&emitter);
    try testing.expect(emitter.buffer[0] == 0x90);
}

test "stub" {
    const stub_count = 80;
    const pos = 2;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try em.Emitter.init(allocator, 4);
    defer emitter.deinit();
    emitter.ip = pos;

    const start_i: usize = try stub(&emitter, 0x91, stub_count);
    var i: usize = emitter.ip;

    while (i <= stub_count) : (i = i + 1) {
        try testing.expect(emitter.buffer[i] == 0x91);
    }

    try testing.expect(start_i == pos);
}

test "rex" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try em.Emitter.init(allocator, 4);
    defer emitter.deinit();

    try rex(&emitter, 1, 0, 0, 0);
    try rex(&emitter, 0, 1, 0, 0);
    try rex(&emitter, 0, 0, 1, 0);
    try rex(&emitter, 0, 0, 0, 1);

    try testing.expect(emitter.buffer[0] == 0x48);
    try testing.expect(emitter.buffer[1] == 0x44);
    try testing.expect(emitter.buffer[2] == 0x42);
    try testing.expect(emitter.buffer[3] == 0x41);
}

test "modrm" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try em.Emitter.init(allocator, 2);
    defer emitter.deinit();

    try modrm(&emitter, 0b11, castReg(Register.rax), castReg(Register.rbx));
    try modrm(&emitter, 0b10, castReg(Register.rdx), castReg(Register.rsi));

    try testing.expect(emitter.buffer[0] == 0xC3);

    try testing.expect(emitter.buffer[1] == 0x96);
}

test "sib" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try em.Emitter.init(allocator, 3);
    defer emitter.deinit();

    try sib(&emitter, 0, 0b100, castReg(Register.rbx));
    try sib(&emitter, 0, castReg(Register.rax), castReg(Register.rdi));
    try sib(&emitter, 8, castReg(Register.rbx), castReg(Register.rsi));

    try testing.expect(emitter.buffer[0] == 0x23);
    try testing.expect(emitter.buffer[1] == 0x07);
    try testing.expect(emitter.buffer[2] == 0x1E);
}

pub fn main() void {}

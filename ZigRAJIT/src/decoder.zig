const std = @import("std");
const opcodes = @import("enum/opcodes.zig");

const testing = std.testing;

pub const Opcode = opcodes.Opcode;

pub const DecodeError = error{
    UnexpectedEndOfBytecode,
    UnknownOpcode,
    InvalidNameTerminator,
};

pub const Instruction = struct {
    opcode: Opcode,
    operands: []const u8,
    next_ip: usize,
};

fn readByte(buffer: []const u8, ip: usize) DecodeError!u8 {
    if (ip >= buffer.len) return error.UnexpectedEndOfBytecode;
    return buffer[ip];
}

fn nameOperandLength(buffer: []const u8, operands_ip: usize) DecodeError!usize {
    _ = try readByte(buffer, operands_ip);

    var ip = operands_ip + 1;
    while (ip < buffer.len) : (ip += 1) {
        if (buffer[ip] == 0) {
            return 1 + (ip - operands_ip);
        }
    }

    return error.InvalidNameTerminator;
}

pub fn nameFromOperands(operands: []const u8) []const u8 {
    const name_area = operands[1..];
    const name_end = std.mem.indexOfScalar(u8, name_area, 0) orelse name_area.len;
    return name_area[0..name_end];
}

fn operandLength(buffer: []const u8, opcode_ip: usize, opcode: Opcode) DecodeError!usize {
    const operands_ip = opcode_ip + 1;

    return switch (opcode) {
        .rem, .dup, .end, .end_prg => 0,
        .push, .ret, .not => 1,
        .add,
        .sub,
        .mul,
        .div,
        .andop,
        .orop,
        .xor,
        .shl,
        .shr,
        .cmpeq,
        .cmpgt,
        .cmptlt,
        .drf,
        .drfs,
        .load,
        .store,
        .loadp,
        .storep,
        => 2,
        .invoke, .includestatic, .includenear => try nameOperandLength(buffer, operands_ip),
        .fn_decl => (try nameOperandLength(buffer, operands_ip)) + 2,
    };
}

pub fn decode(buffer: []const u8, ip: usize) DecodeError!Instruction {
    const byte = try readByte(buffer, ip);
    const opcode = std.enums.fromInt(Opcode, byte) orelse return error.UnknownOpcode;
    const operands_len = try operandLength(buffer, ip, opcode);
    const next_ip = ip + 1 + operands_len;

    if (next_ip > buffer.len) return error.UnexpectedEndOfBytecode;

    return Instruction{
        .opcode = opcode,
        .operands = buffer[ip + 1 .. next_ip],
        .next_ip = next_ip,
    };
}

test "decode operand-less instructions" {
    try testing.expectEqual(Opcode.rem, (try decode(&[_]u8{0x01}, 0)).opcode);
    try testing.expectEqual(@as(usize, 1), (try decode(&[_]u8{0x01}, 0)).next_ip);
    try testing.expectEqual(Opcode.dup, (try decode(&[_]u8{0x02}, 0)).opcode);
    try testing.expectEqual(Opcode.end, (try decode(&[_]u8{0x5F}, 0)).opcode);
    try testing.expectEqual(Opcode.end_prg, (try decode(&[_]u8{0xFE}, 0)).opcode);
}

test "decode push and ret operands" {
    const push = try decode(&[_]u8{ 0x00, 0x2A }, 0);
    try testing.expectEqual(Opcode.push, push.opcode);
    try testing.expectEqualSlices(u8, &[_]u8{0x2A}, push.operands);
    try testing.expectEqual(@as(usize, 2), push.next_ip);

    const ret = try decode(&[_]u8{ 0x07, 0xDE }, 0);
    try testing.expectEqual(Opcode.ret, ret.opcode);
    try testing.expectEqualSlices(u8, &[_]u8{0xDE}, ret.operands);
    try testing.expectEqual(@as(usize, 2), ret.next_ip);
}

test "decode arithmetic operands" {
    const add = try decode(&[_]u8{ 0x10, 0x05, 0x04 }, 0);
    try testing.expectEqual(Opcode.add, add.opcode);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x05, 0x04 }, add.operands);
    try testing.expectEqual(@as(usize, 3), add.next_ip);
}

test "decode invoke with length-prefixed, NUL-terminated name" {
    const buffer = [_]u8{ 0x0B, 3, 'f', 'o', 'o', 0 };
    const invoke = try decode(&buffer, 0);
    try testing.expectEqual(Opcode.invoke, invoke.opcode);
    try testing.expectEqualSlices(u8, &[_]u8{ 3, 'f', 'o', 'o', 0 }, invoke.operands);
    try testing.expectEqual(@as(usize, 6), invoke.next_ip);
}

test "decode fn_decl with length-prefixed, NUL-terminated name, locals and args" {
    const buffer = [_]u8{ 0x1F, 5, 't', 'e', 's', 't', 'A', 0, 2, 1 };
    const fn_decl = try decode(&buffer, 0);
    try testing.expectEqual(Opcode.fn_decl, fn_decl.opcode);
    try testing.expectEqualSlices(u8, &[_]u8{ 5, 't', 'e', 's', 't', 'A', 0, 2, 1 }, fn_decl.operands);
    try testing.expectEqual(@as(usize, 10), fn_decl.next_ip);
}

test "decode ignores an incorrect name length byte" {
    const buffer = [_]u8{ 0x0B, 18, 'f', 'o', 'o', 0 };
    const invoke = try decode(&buffer, 0);
    try testing.expectEqual(@as(usize, 6), invoke.next_ip);
    try testing.expectEqualSlices(u8, "foo", nameFromOperands(invoke.operands));
}

test "decode from non-zero ip" {
    const buffer = [_]u8{ 0x01, 0x00, 0x2A };
    const push = try decode(&buffer, 1);
    try testing.expectEqual(Opcode.push, push.opcode);
    try testing.expectEqualSlices(u8, &[_]u8{0x2A}, push.operands);
    try testing.expectEqual(@as(usize, 3), push.next_ip);
}

test "decode rejects unknown opcode" {
    try testing.expectError(error.UnknownOpcode, decode(&[_]u8{0x99}, 0));
}

test "decode rejects truncated instruction" {
    try testing.expectError(error.UnexpectedEndOfBytecode, decode(&[_]u8{0x00}, 0));
    try testing.expectError(error.UnexpectedEndOfBytecode, decode(&[_]u8{}, 0));
    try testing.expectError(error.UnexpectedEndOfBytecode, decode(&[_]u8{ 0x1F, 1, 'f', 0, 0 }, 0));
}

test "decode rejects a name without NUL terminator" {
    try testing.expectError(error.InvalidNameTerminator, decode(&[_]u8{ 0x0B, 5, 'f' }, 0));
    try testing.expectError(error.InvalidNameTerminator, decode(&[_]u8{ 0x0B, 3, 'f', 'o', 'o', 'x' }, 0));
    try testing.expectError(error.InvalidNameTerminator, decode(&[_]u8{ 0x1F, 1, 'f', 'x', 'y' }, 0));
}

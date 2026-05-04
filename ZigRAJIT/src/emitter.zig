const std = @import("std");
const logger = @import("logger.zig");
const KB = 1024;
const testing = std.testing;
const EmitterError = error{
    ErrorExternalBufferTooSmall,
    ErrorMemoryExhausted,
    NoAllocator,
};

pub const Emitter = struct {
    buffer: []u8,
    buffer_size: usize,
    ip: usize,
    owns_buffer: bool,
    allocator: ?std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, initial_size: usize) !Emitter {
        const bufPrt = try allocator.alloc(u8, initial_size);
        return Emitter{
            .buffer = bufPrt,
            .buffer_size = initial_size,
            .ip = 0,
            .owns_buffer = true,
            .allocator = allocator,
        };
    }

    pub fn initWithBuffer(buffer: []u8) Emitter {
        return Emitter{
            .buffer = buffer,
            .buffer_size = buffer.len,
            .ip = 0,
            .owns_buffer = false,
            .allocator = null,
            .page_allocator = null,
        };
    }

    pub fn deinit(self: *Emitter) void {
        if (!self.owns_buffer) return;

        if (self.allocator) |alloc| {
            alloc.free(self.buffer);
        }
    }

    fn getAllocator(self: *Emitter) !std.mem.Allocator {
        if (self.allocator) |alloc| {
            return alloc;
        } else {
            return EmitterError.NoAllocator;
        }
    }

    fn growBufferToSmallerSize(self: *Emitter) ![]u8 {
        const alloc = try self.getAllocator();
        const PercentsOfGrowing = [_]f32{ 0.75, 0.50, 0.25, 0.20, 0.10, 0.05 };

        for (PercentsOfGrowing) |percent| {
            const new_size = @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(self.buffer.len)) * (1.0 + percent))));

            if (alloc.alloc(u8, new_size)) |buf| {
                return buf;
            } else |err| switch (err) {
                error.OutOfMemory => continue,
                else => return err,
            }
        }
        return EmitterError.ErrorMemoryExhausted;
    }

    pub fn growBuffer(self: *Emitter) !void {
        if (!self.owns_buffer) {
            logger.fatal("an external buffer is too small", .{});
            return EmitterError.ErrorExternalBufferTooSmall;
        }

        const alloc = try self.getAllocator();
        var newbuf: []u8 = undefined;

        if (self.buffer.len < 4 * KB) {
            newbuf = alloc.alloc(u8, 4 * KB) catch |err| switch (err) {
                error.OutOfMemory => try self.growBufferToSmallerSize(),
                else => return err,
            };
            self.buffer_size = 4 * KB;
        } else {
            const double_size = 2 * self.buffer.len;
            newbuf = alloc.alloc(u8, double_size) catch |err| switch (err) {
                error.OutOfMemory => try self.growBufferToSmallerSize(),
                else => return err,
            };
            self.buffer_size = double_size;
        }

        if (newbuf.len > self.buffer.len) {
            @memcpy(newbuf[0..self.buffer.len], self.buffer[0..self.buffer.len]);
        } else {
            logger.fatal("new buffer not growth", .{});
            return EmitterError.ErrorExternalBufferTooSmall;
        }

        alloc.free(self.buffer);
        self.buffer = newbuf;
    }

    fn overflow(self: *Emitter) bool {
        return self.ip >= self.buffer.len;
    }

    pub fn ensureSpace(self: *Emitter) !void {
        if (self.overflow()) {
            try self.growBuffer();
        }
    }

    pub fn ip(self: *Emitter) usize {
    return self.ip;
    }

    pub fn buffer(self: *Emitter) []u8 {
        return self.buffer;
    }

    pub fn buffer_size(self: *Emitter) usize { 
        return self.buffer_size;
    }

    pub fn owns_buffer(self: *Emitter) bool {
    return self.owns_buffer;
    }

    pub fn emit(self: *Emitter, byte: u8) !void {
        try self.ensureSpace();
        self.buffer[self.ip] = byte;
        self.ip += 1;
    }

    pub fn emitS(self: *Emitter, bytes: []const u8) !void {
        for (bytes) |byte| {
            try self.emit(byte);
        }
    }

    pub fn emitWord(self: *Emitter, word: u16) !void {
        try self.emit(@truncate(word));
        try self.emit(@truncate(word >> 8));
    }

    pub fn emitDWord(self: *Emitter, dword: u32) !void {
        try self.emit(@truncate(dword));
        try self.emit(@truncate(dword >> 8));
        try self.emit(@truncate(dword >> 16));
        try self.emit(@truncate(dword >> 24));
    }

    pub fn emitQuad(self: *Emitter, quad: u64) !void {
        try self.emit(@truncate(quad));
        try self.emit(@truncate(quad >> 8));
        try self.emit(@truncate(quad >> 16));
        try self.emit(@truncate(quad >> 24));
        try self.emit(@truncate(quad >> 32));
        try self.emit(@truncate(quad >> 40));
        try self.emit(@truncate(quad >> 48));
        try self.emit(@truncate(quad >> 56));
    }

    pub fn getPrevByte(self: *Emitter) u8 {
        if (self.ip == 0) return 0;
        return self.buffer[self.ip - 2];
    }

    pub fn getCurrByte(self: *Emitter) u8 {
        if (self.ip == 0) return 0;
        return self.buffer[self.ip - 1];
    }
};

test "Testing emit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try Emitter.init(allocator, 10);
    defer emitter.deinit();

    try emitter.emit(0xAA);
    try testing.expect(emitter.ip == 1);
    try testing.expect(emitter.buffer[0] == 0xAA);
}

test "Testing emitS" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try Emitter.init(allocator, 10);
    defer emitter.deinit();

    const bytes = [_]u8{ 0xAA, 0xBB, 0xCC };
    try emitter.emitS(&bytes);

    try testing.expect(emitter.ip == 3);
    try testing.expect(emitter.buffer[0] == 0xAA);
    try testing.expect(emitter.buffer[1] == 0xBB);
    try testing.expect(emitter.buffer[2] == 0xCC);
}

test "Testing emitWord" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try Emitter.init(allocator, 10);
    defer emitter.deinit();

    try emitter.emitWord(0xAABB);
    try testing.expect(emitter.ip == 2);
    try testing.expect(emitter.buffer[0] == 0xBB);
    try testing.expect(emitter.buffer[1] == 0xAA);
}

test "Testing emitDWord" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try Emitter.init(allocator, 10);
    defer emitter.deinit();

    try emitter.emitDWord(0xAABBCCDD);
    try testing.expect(emitter.ip == 4);
    try testing.expect(emitter.buffer[0] == 0xDD);
    try testing.expect(emitter.buffer[3] == 0xAA);
}

test "Testing emitQuad" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try Emitter.init(allocator, 20);
    defer emitter.deinit();

    try emitter.emitQuad(0x1122334455667788);
    try testing.expect(emitter.ip == 8);
    try testing.expect(emitter.buffer[0] == 0x88);
    try testing.expect(emitter.buffer[7] == 0x11);
}

test "Testing getPrevByte" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try Emitter.init(allocator, 2);
    defer emitter.deinit();

    try emitter.emit(0x0F);
    try emitter.emit(0xFF);
    try testing.expect(emitter.getPrevByte() == 0x0F);
}

test "Testing getCurrByte" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var emitter = try Emitter.init(allocator, 2);
    defer emitter.deinit();

    try emitter.emit(0x0F);
    try emitter.emit(0xAA);
    try testing.expect(emitter.getCurrByte() == 0xAA);
}

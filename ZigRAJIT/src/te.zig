const s = @import("std");

pub fn main() void{
const v = @max(0.75,10);
s.debug.print("{d}\n", .{v});
}


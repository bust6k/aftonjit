
const std = @import("std");


// Argument placeholders
//
/// This enum is used for accepting argument values for something purposes
///
///Working with arguments is same as in other languages,but with important diffirents:
///
///- arguments hasn't names. It's just placeholders. It more comfortable for AftonJIT
///- count arguments cannot be greater than 6. It's part of design 
pub const ArgSlot = enum(u8) {
    arg1 = 0x1A,
    arg2 = 0x2A,
    arg3 = 0x3A,
    arg4 = 0x4A,
    arg5 = 0x5A,
    arg6 = 0x6A,
    
};

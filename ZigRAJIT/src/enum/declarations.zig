
const std = @import("std");


// Type declarations
/// Since now type declarations not implemented,here's no description for it
pub const TypeDecl = enum(u8) {
    int = 0x2F,
    char = 0x5F,
    short = 0x6F,
    ptr = 0x3F,
    structop = 0x4F,
    
};

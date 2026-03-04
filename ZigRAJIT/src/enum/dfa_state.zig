//! dfa module storages DFA states for AftonJIT optimizer engine
//!
//! so,it storages states for DFA Constant Folding(DFA CF)
//!
//! and for DFA dead code elimination(DFA DCE)
//!
//! but keep in mind, these optimizations so primitive because they uses small count of states
//!
//! but it also fast
const std = @import("std");


// Parser DFA states
pub const ParseState = enum(u8) {
    start = 0x01,
    arg1 = 0x02,
    arg2 = 0x03,
    folding = 0x04,
    
};

pub const ParseInputType = enum(u8) {
    op = 0x01,
    arg1 = 0x02,
    arg2 = 0x03,
    
};

// DCE DFA states
pub const DceState = enum(u8) {
    start = 0x01,
    instr1 = 0x02,
    instr2 = 0x03,
    dce = 0x04,
    
};

pub const DceInputType = enum(u8) {
    instr1 = 0x01,
    instr2 = 0x02,
    end = 0x03,
    
};

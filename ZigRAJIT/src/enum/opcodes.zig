const std = @import("std");

/// This enum is bytecode instructions for AftonJIT compiler
///
/// This enum makes instruction set architecture(ISA) for making Afton proggrams executed by AftonJIT
///
/// every instruction has its own opcode
///
/// If insturciton has arguments,then arguments need to follow  near to instruction bytecode
///
/// something instructions have special arg-values for set new beheivor aside common. Example: RET instruction.
///
/// Description of every instruction has strict structure:
///
/// SYNOPSYS for instruction
///
/// OPCODE of instruction
///
/// EXAMPLE that try to cover all  using cases of instruction
///
/// SIDE EFFECTS that say about side effects at stack,other variables,etc.
pub const Opcode = enum(u8) {
    //Stack operations

    /// push operation pushes value/variable/argument onto the stack.
    ///
    /// Opcode: 0x00.
    ///
    /// Example:
    ///
    /// ```
    /// push  5 (00 5)
    ///
    /// push arg1 (00 1a)
    ///
    /// push x (00 x)
    ///
    /// ```
    ///
    /// Side effects: no.
    push = 0x00,
    /// rem operation removes the current stack value
    ///
    /// Opcode: 0x01
    ///
    /// Example:
    ///
    /// ```
    /// push F (00 0f)
    ///
    ///
    /// rem (01)
    ///
    /// ```
    ///
    /// Side effects: no.
    rem = 0x01,
    /// dup operation makes new copy of current value of stack and put it at the stack top
    ///
    /// Opcode: 0x02
    ///
    /// Example:
    ///
    /// ```
    /// push 100 (00 100)
    ///
    /// dup (02)
    ///
    /// ```
    ///
    /// Side effects: dup instruction uses rax register for storaging the current stack value
    dup = 0x02,
    /// ret operation returns value/argument/variable
    ///
    /// Opcode: 0x07
    ///
    /// Example:
    ///
    /// ```
    /// fn 3 foo 0 0 (1f 3 foo 0 0)
    /// ...
    /// ret 42 (07 42)
    /// ```
    ///
    /// Side effects: uses eax for returning values. Also has special argument-values
    ret = 0x07,

    // Arithmetic

    /// add operation adds value from 1-rst argument at 2-cond argument. Argument maybe value/variable/argument
    ///
    /// Opcode: 0x10
    ///
    /// Example:
    ///
    /// ```
    /// add 10 3 (10 10 3)
    /// add 5 x (10 5 x)
    /// add arg1 arg5 (10 1a 5a)
    /// ```
    ///
    /// Side effects: add instruction puts computed value at the stack. for computing uses r8 and r9 registers.
    add = 0x10,
    /// sub operation does same as add but make substracting
    ///
    /// Opcode: 0x17
    ///
    /// Example:
    ///
    /// ```
    /// sub arg6 x (17 6a x)
    /// sub x 10 (17 x 10)
    ///```
    /// Side effects: same as with add
    sub = 0x17,
    /// mul operation does same as sub but make multiplying
    ///
    /// Opcode: 0x18
    ///
    /// Example:
    ///
    /// ```
    /// mul arg4 legn (18 4a legn)
    /// mul 5 4 (18 5 4)
    /// ```
    ///
    /// Side effects: same as with sub
    mul = 0x18,
    /// dib operation does same as mul but make dividing
    ///
    /// Opcode: 0x19
    ///
    /// Example:
    ///
    /// ```
    /// div arg1 10 (19 1a 10)
    /// ```
    ///
    /// Side effects: same as with mul
    div = 0x19,
    // Bitwise
    andop = 0x03,
    orop = 0x04,
    not = 0x05,
    xor = 0x06,
    shl = 0x0D,
    shr = 0x0E,

    // Comparison
    cmpeq = 0x08,
    cmpgt = 0x09,
    cmptlt = 0x0C,

    // Memory operations
    drf = 0x0F,
    drfs = 0x16,
    load = 0x13,
    store = 0x12,
    loadp = 0x15,
    storep = 0x14,

    // Control flow / invocation
    includestatic = 0x0A,
    includenear = 0x11,
    /// invoke operation make invocation of function. Passes to arguments function name length  and  function name
    ///
    /// Opcode: 0x0B
    ///
    /// Example:
    ///
    /// ```
    /// invoke 5 fostr (0b 5 fostr)
    /// invoke 3 the (0b 3 the)
    /// ```
    ///
    /// Side effects: Since under the hood invoke uses absolute call offset,it uses r11 register as well as accumulator  for function addres
    invoke = 0x0B,

    // Special markers

    /// fn_decl operation declarates a new function. Passes function name length,function name,count of local variables and count of arguments
    ///
    /// Opcode: 0x1F
    ///
    /// Example:
    ///
    /// ```
    /// fn 3 foo 0 0 (1f 3 foo 0 0)
    /// fn 6 golang 1 4 (1f 6 golang 1 4)
    /// ```
    ///
    /// Side effects: At runtime it makes new record  at function table. Makes prologue in function start
    fn_decl = 0x1F,
    /// end operation is a marker for ending the current function
    ///
    /// Opcode: 0x5F
    ///
    /// Example:
    ///
    /// ```
    /// fn 1 f 0 0 (1f 1 f 0 0)
    /// ...
    /// end (5f)
    /// ```
    ///
    /// Side effects: no.
    end = 0x5F,
    /// end_prg operation is a marker for ending proggram
    ///
    /// Opcode: 0xFE
    ///
    /// Example:
    ///
    /// ```
    /// fn 4 rust 0 0 (1f 4 rust 0 0)
    /// ...
    /// end (5f)
    /// end_prg(fe)
    /// ```
    ///
    /// Side effects: no.
    end_prg = 0xFE,
};

///This enum is special arg-values for ret instruction
///
///These arg-values changes the default behaivor of instruction
pub const RetExtension = enum(u8) {
    /// void exension says ret instruction return nothing
    ///
    /// Opcode: 0xFF
    ///
    /// Example:
    /// ```
    /// ret void (07 ff)
    /// ```
    ///
    /// Side effects: no.
    void = 0xFF,
    /// stack extension says ret instruction return the last value from stack
    ///
    /// Opcode: 0xDE
    ///
    /// Example:
    /// ```
    /// push FF (00 ff)
    /// ret stack (07 de)
    /// ```
    ///
    /// Side effects: uses rax for returning last value.
    stack = 0xDE,
    ///val extension says ret instruction return the passed value/variable's value
    val = 0x00,
};

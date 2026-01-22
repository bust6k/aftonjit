// This file is generator for each test uses all opportunities of the current JIT-engine
// AFFE - is magic for afton byte-code of version 2
// version 2 - is current byte-code format version. It means,the first version supports only:
// 1. 9 instructions: push,rem,ret,invoke(arguments not support) ,dup, sub, add,mul,div
// 2. function declaration
// 3. basic byte-code markers - AFFE like magic number,and 2 like format version
// WARNING: magic number may vary from first byte-code versions and soon it will going stable

import * as std from "std"

function addCString(buffer, offset, s) {
    for (let i = 0; i < s.length; i++) buffer[offset++] = s.charCodeAt(i);
    buffer[offset++] = 0;
    return offset;
}

function createUint32(buffer, offset, value) {
    buffer[offset] = value & 0xFF;
    buffer[offset + 1] = (value >> 8) & 0xFF;
    buffer[offset + 2] = (value >> 16) & 0xFF;
    buffer[offset + 3] = (value >> 24) & 0xFF;
    return offset + 4;
}

function createBasicWorkWithStackFile() {
    let code = new Uint8Array(100);
    let o = 0;
    code[o++] = 0x02;
    o = createUint32(code, o, 0xAFFE);
    code[o++] = 0x1F;
    code[o++] = 0x03;
    o = addCString(code, o, "foo");
    code[o++] = 0x00;
    code[o++] = 0x00;
    code[o++] = 0x00;
    code[o++] = 0x0F;
    code[o++] = 0x02;
    code[o++] = 0x02;
    code[o++] = 0x01;
    code[o++] = 0x07;
    code[o++] = 0xFF;
    code[o++] = 0x5F;
    code[o++] = 0x1F;
    code[o++] = 0x04;
    o = addCString(code, o, "main");
    code[o++] = 0x00;
    code[o++] = 0x00;
    code[o++] = 0xB;
    code[o++] = 0x03;
    o = addCString(code, o, "foo");
    code[o++] = 0x00;
    code[o++] = 0x10;
    code[o++] = 0x02;
    code[o++] = 0x01;
    code[o++] = 0xB;
    o = addCString(code, o, "foo");
    code[o++] = 0x07;
    code[o++] = 0x12;
    code[o++] = 0x5F;
    code[o++] = 0xFE;
    return code.slice(0, o);
}

function createSimpleProgramFile() {
    let code = new Uint8Array(80);
    let o = 0;
    code[o++] = 0x02;
    o = createUint32(code, o, 0xAFFE);
    code[o++] = 0x1F;
    code[o++] = 0x03;
    o = addCString(code, o, "foo");
    code[o++] = 0x00;
    code[o++] = 0x00;
    code[o++] = 0x00;
    code[o++] = 0x01;
    code[o++] = 0x01;
    code[o++] = 0x07;
    code[o++] = 0x40;
    code[o++] = 0x5F;
    code[o++] = 0x1F;
    code[o++] = 0x04;
    o = addCString(code, o, "main");
    code[o++] = 0x00;
    code[o++] = 0x00;
    code[o++] = 0x0B;
    code[o++] = 0x03;
    o = addCString(code, o, "foo");
    code[o++] = 0x07;
    code[o++] = 0xFF;
    code[o++] = 0x5F;
    code[o++] = 0xFE;
    return code.slice(0, o);
}

function createRetTestFile() {
    let code = new Uint8Array(50);
    let o = 0;
    code[o++] = 0x02;
    o = createUint32(code, o, 0xAFFE);
    code[o++] = 0x1F;
    code[o++] = 0x12;
    o = addCString(code, o, "test_ret_prg");
    code[o++] = 0x00;
    code[o++] = 0x00;
    code[o++] = 0x01;
    code[o++] = 0x07;
    code[o++] = 0xDE;
    code[o++] = 0x5F;
    code[o++] = 0xFE;
    return code.slice(0, o);
}

function createWrongByHeaderFile() {
    let code = new Uint8Array(30);
    let o = 0;
    code[o++] = 0x1F;
    code[o++] = 0x01;
    o = addCString(code, o, "f");
    code[o++] = 0x00;
    code[o++] = 0x00;
    code[o++] = 0x07;
    code[o++] = 0xFF;
    code[o++] = 0x5F;
    code[o++] = 0xFE;
    return code.slice(0, o);
}

function writeFile(name, data) {
    let f = std.open(name, "w");
    let str = "";
    for (let i = 0; i < data.length; i++) {
        str += String.fromCharCode(data[i]);
    }
    f.puts(str);
    f.close(); 
}

writeFile('test_base.afton', createBasicWorkWithStackFile());
writeFile('test_simple.afton', createSimpleProgramFile());
writeFile('test_ret.afton', createRetTestFile());
writeFile('test_wrong.afton', createWrongByHeaderFile());
print("test files generated");

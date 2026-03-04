-- This file is generator for each test uses all opportunities of the current JIT-engine
-- AFFE - is magic for afton byte-code of version 2
-- version 2 - is current byte-code format version. It means,the second version supports only:
-- 1. 9 instructions: push,rem,ret,invoke(arguments not support) ,dup, sub, add,mul,div
-- 2. function declaration
-- 3. basic byte-code markers - AFFE like magic number,and 2 like format version
-- WARNING: magic number may vary from first byte-code versions and soon it will going stable


--XXX: The problem of undefined C2 byte in hexdump extractly not in generation. Can to assume,it goes because i'm allowing change bytes i'm writing by missing  b mode in setting 
--file rights in writeFile() function

function addCString(buffer, offset, s)
    for i = 1, #s do
        buffer[offset] = string.byte(s, i)
        offset = offset + 1
    end
    buffer[offset] = 0
    return offset + 1
end

allow_gen = true

function createUint32(buffer, offset, value)
    buffer[offset] = value & 0xFF
    buffer[offset + 1] = (value >> 8) & 0xFF
    buffer[offset + 2] = (value >> 16) & 0xFF
    buffer[offset + 3] = (value >> 24) & 0xFF
    return offset + 4
end

function createBasicWorkWithStackFile()
    local code = {}
    local o = 1
    code[o] = 0x02
    o = o + 1
--    o = createUint32(code, o, 0xAFFE)
    code[o] = 0xAF
    o = o + 1
    code[o] = 0x1F
    o = o + 1
    code[o] = 0x03
    o = o + 1
    o = addCString(code, o, "foo")
    code[o] = 0x00
    o = o + 1
    code[o] = 0x00
    o = o + 1
    code[o] = 0x00
    o = o + 1
    code[o] = 0x0F
    o = o + 1
    code[o] = 0x02
    o = o + 1
    code[o] = 0x02
    o = o + 1
    code[o] = 0x01
    o = o + 1
    code[o] = 0x07
    o = o + 1
    code[o] = 0xFF
    o = o + 1
    code[o] = 0x5F
    o = o + 1
    code[o] = 0x1F
    o = o + 1
    code[o] = 0x04
    o = o + 1
    o = addCString(code, o, "main")
    code[o] = 0x00
    o = o + 1
    code[o] = 0x00
    o = o + 1
    code[o] = 0xB
    o = o + 1
    code[o] = 0x03
    o = o + 1
    o = addCString(code, o, "foo")
    code[o] = 0x00
    o = o + 1
    code[o] = 0x10
    o = o + 1
    code[o] = 0x02
    o = o + 1
    code[o] = 0x01
    o = o + 1
    code[o] = 0xB
    o = o + 1
    o = addCString(code, o, "foo")
    code[o] = 0x07
    o = o + 1
    code[o] = 0x12
    o = o + 1
    code[o] = 0x5F
    o = o + 1
    code[o] = 0xFE
    o = o + 1
    
    local result = {}
    for i = 1, o-1 do
        result[i] = code[i]
    end
    return result
end

function createSimpleProgramFile()
    local code = {}
    local o = 1
    code[o] = 0x02
    o = o + 1
--    o = createUint32(code, o, 0xAFFE)
    code[o] = 0xAF
    o = o + 1
    code[o] = 0x1F
    o = o + 1
    code[o] = 0x03
    o = o + 1
    o = addCString(code, o, "foo")
    code[o] = 0x00
    o = o + 1
    code[o] = 0x00
    o = o + 1
    code[o] = 0x00
    o = o + 1
    code[o] = 0x01
    o = o + 1
    code[o] = 0x01
    o = o + 1
    code[o] = 0x07
    o = o + 1
    code[o] = 0x40
    o = o + 1
    code[o] = 0x5F
    o = o + 1
    code[o] = 0x1F
    o = o + 1
    code[o] = 0x04
    o = o + 1
    o = addCString(code, o, "main")
    code[o] = 0x00
    o = o + 1
    code[o] = 0x00
    o = o + 1
    code[o] = 0x0B
    o = o + 1
    code[o] = 0x03
    o = o + 1
    o = addCString(code, o, "foo")
    code[o] = 0x07
    o = o + 1
    code[o] = 0xFF
    o = o + 1
    code[o] = 0x5F
    o = o + 1
    code[o] = 0xFE
    o = o + 1
    
    local result = {}
    for i = 1, o-1 do
        result[i] = code[i]
    end
    return result
end

function createRetTestFile()
    local code = {}
    local o = 1
    code[o] = 0x02
    o = o + 1
--    o = createUint32(code, o, 0xAFFE)
    code[o] = 0xAF
    o = o + 1
    code[o] = 0x1F
    o = o + 1
    code[o] = 0x12
    o = o + 1
    o = addCString(code, o, "test_ret_prg")
    code[o] = 0x00
    o = o + 1
    code[o] = 0x00
    o = o + 1
    code[o] = 0x01
    o = o + 1
    code[o] = 0x07
    o = o + 1
    code[o] = 0xDE
    o = o + 1
    code[o] = 0x5F
    o = o + 1
    code[o] = 0xFE
    o = o + 1
    
    io.write("Uint8Array [")
    for i = 1, o-1 do
        if i > 1 then io.write(" ") end
        io.write(string.format("0x%X", code[i]))
    end
    io.write("]\n")
    
    local result = {}
    for i = 1, o-1 do
        result[i] = code[i]
    end
    return result
end

function createWrongByHeaderFile()
    local code = {}
    local o = 1
    code[o] = 0x1F
    o = o + 1
    code[o] = 0x01
    o = o + 1
    o = addCString(code, o, "f")
    code[o] = 0x00
    o = o + 1
    code[o] = 0x00
    o = o + 1
    code[o] = 0x07
    o = o + 1
    code[o] = 0xFF
    o = o + 1
    code[o] = 0x5F
    o = o + 1
    code[o] = 0xFE
    o = o + 1
   
    io.write("\n[[The Afton Bytecode for testing of wrong code#4]]\n\n")
    io.write("Uint8Array[")
    for  i = 1,o -1 do
    if i > 1 then io.write(" ") end
    io.write("0x%02X,",code[i])
    end
    io.write("]\n\n")
    local result = {}
    for i = 1, o-1 do
        result[i] = code[i]
    end
    return result
end

function testConstantFolding()
    local code = {}
    local o = 1
    code[o] = 0x02
    o = o + 1
--    o = createUint32(code, o, 0xAFFE)
    code[o] = 0xAF
    o = o + 1
    code[o] = 0x1F
    o = o + 1
    code[o] = 0x05
    o = o + 1
    o = addCString(code, o, "foooo")
    code[o] = 0x00
    o = o + 1
    code[o] = 0x00
    o = o + 1
    code[o] = 0x10
    o = o + 1
    code[o] = 0x40
    o = o + 1
    code[o] = 0x50
    o = o + 1
    code[o] = 0x17
    o = o + 1
    code[o] = 0x50
    o = o + 1
    code[o] = 0x10
    o = o + 1
    code[o] = 0x18
    o = o + 1
    code[o] = 0x05
    o = o + 1
    code[o] = 0x04
    o = o + 1
    code[o] = 0x19
    o = o + 1
    code[o] = 0x14
    o = o + 1
    code[o] = 0x04
    o = o + 1
    code[o] = 0x07
    o = o +1
    code[o] = 0xFF
    o = o + 1
    code[o] = 0x5F
    o = o + 1
    code[o] = 0xFE
    o = o + 1

    io.write("\n[[The Afton Bytecode for testing of constant folding#5]]\n\n")
    io.write("Uint8Array [")
    for i = 1, o-1 do
        if i > 1 then io.write(" ") end
        io.write(string.format("0x%02X", code[i]))
    end
    io.write("]\n\n")
    
    local result = {}
    for i = 1, o-1 do
        result[i] = code[i]
    end
    return result
end

function testDeadCodeElimination()
    local code = {}
    local o = 1
    code[o] = 0x02
    o = o + 1
--    o = createUint32(code, o, 0xAFFE)
    code[o] = 0xAF
    o = o + 1
    code[o] = 0x1F
    o = o + 1
    code[o] = 0x05
    o = o + 1
    o = addCString(code, o, "foooo")
    code[o] = 0x00
    o = o + 1
    code[o] = 0x00
    o = o + 1
    code[o] = 0x01
    o = o + 1
    code[o] = 0x02
    o = o + 1
    code[o] = 0x01
    o = o + 1
    code[o] = 0x07
    o = o + 1
    code[o] = 0xFF
    o = o + 1
    code[o] = 0x5F
    o = o + 1
    code[o] = 0xFE
    o = o + 1
    
    local result = {}
    for i = 1, o-1 do
        result[i] = code[i]
    end
    return result
end

function writeFile(name, data)
    local f = io.open(name, "wb")
    local str = {}
    for i = 1, #data do
        str[i] = string.char(data[i])
    end
    f:write(table.concat(str))
    f:close()
end

function main()
if allow_gen == true then
    writeFile('test_base.afton', createBasicWorkWithStackFile())
    writeFile('test_simple.afton', createSimpleProgramFile())
    writeFile('test_ret.afton', createRetTestFile())
    writeFile('test_wrong.afton', createWrongByHeaderFile())
    writeFile('test_cf.afton', testConstantFolding())
    writeFile('test_dce.afton', testDeadCodeElimination())
    print("test files generated")
end
end

main()

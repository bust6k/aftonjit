import struct

"""
This file is generator for each test  uses all opportunies of the  current JIT-engine

FFF - is magic for afton byte-code of version 1

version 1 - is current byte-code format version. It means,the first version supports only:

1. 5 instructions: push,rem,ret,invoke(arguments not support) ,dup

2. function declaration

3. basic byte-code markers - FFF like magic number,and 1 like format version


WARNING: magic number may vary from first byte-code versions and soon it will going stable
"""

def add_c_string(code, s):
    code.extend(s.encode('utf-8'))
    code.append(0x00)  
    
    
def create_basic_work_with_stack_file():    
    code = bytearray()

    code.append(0x01)
    code.extend(struct.pack('<I', 0xFFF))  
    code.append(0x1F)
    code.append(0x03)
    add_c_string(code,"foo")
    code.append(0x00)
    code.append(0x00)
    code.append(0x00)
    code.append(0x0F)
    code.append(0x02)
    code.append(0x02)
    code.append(0x01)
    code.append(0x07)
    code.append(0xFF) 
    code.append(0x5F)
    code.append(0x1F)
    code.append(0x04)
    add_c_string(code,"main")
    code.append(0x00)
    code.append(0x00)
    code.append(0xB)
    code.append(0x03)
    add_c_string(code,"foo")
    code.append(0x00)
    code.append(0x10)
    code.append(0x02)
    code.append(0x01)
    code.append(0xB)
    add_c_string(code,"foo")
    code.append(0x07)
    code.append(0x12)
    code.append(0x5F)
    code.append(0xFE)
    
    with open('test_base.afton', 'wb') as f:
        f.write(code)
    


def create_simple_proggram_file():
    code = bytearray()

    code.append(0x01)
    code.extend(struct.pack('<I', 0xFFF))
    code.append(0x1F)
    code.append(0x03)
    add_c_string(code, "foo")
    code.append(0x00)
    code.append(0x00)
    code.append(0x00)
    code.append(0x01)
    code.append(0x01)
    code.append(0x07)
    code.append(0x40)  
    code.append(0x5F)
    code.append(0x1F)
    code.append(0x04)
    add_c_string(code, "main")
    code.append(0x00)
    code.append(0x00)
    code.append(0x0B)
    code.append(0x03)
    add_c_string(code, "foo")
    code.append(0x07)
    code.append(0xFF)
    code.append(0x5F)
    code.append(0xFE)

    with open('test_simple.afton', 'wb') as f:
        f.write(code)



def create_ret_test_file():
    code = bytearray()

    code.append(0x01)
    code.extend(struct.pack("<I",0xFFF))
    code.append(0x1F)
    code.append(0x12)
    add_c_string(code,"test_ret_prg")
    code.append(0x00)
    code.append(0x00)
    code.append(0x01)
    code.append(0x07)
    code.append(0xDE)
    code.append(0x5F)
    code.append(0xFE)
    
    with open('test_ret.afton', 'wb') as f:
        f.write(code)


def create_wrong_by_header_file():
    code = bytearray()

    code.append(0x1F)
    code.append(0x01)
    add_c_string(code,"f")
    code.append(0x00)
    code.append(0x00)
    code.append(0x07)
    code.append(0xFF)
    code.append(0x5F)
    code.append(0xFE)

    with open('test_wrong.afton', 'wb') as f:
        f.write(code)

if __name__ == "__main__":
    print("All of these generated files you can execute using ./aftonjit \"file\"")

    create_basic_work_with_stack_file()
    print("test_basic.afton file has created")

    create_simple_proggram_file()
    print("test_simple.afton file has created")

    create_ret_test_file()
    print("test_ret.afton file has created")

    create_wrong_by_header_file()
    print("test_wrong.afton has created")

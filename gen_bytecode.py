#!/usr/bin/env python3
import struct

def add_c_string(code, s):

    code.extend(s.encode('utf-8'))
    code.append(0)  
    
    
def create_test_file():
    
    code = bytearray()
    
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
    
    code.extend(struct.pack('<I', 0x000FFFFF))  
    
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
    
    code.append(0x07)
    
    code.extend(struct.pack('<I', 0x000DEADA))
    
    code.append(0x5F)
    
    code.append(0xFE)
    
    with open('test.afton', 'wb') as f:
        f.write(code)
    
    
if __name__ == "__main__":
    create_test_file()


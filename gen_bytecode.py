#!/usr/bin/env python3
import struct

def create_test_file():
    
    code = bytearray()
    
    code.append(0x1F)
    
    code.append(0x00)
    
    code.append(0x00)
    
    code.append(0x00)
    
    code.append(0x0F)
    
    code.append(0x02)
    
    code.append(0x02)
    
    code.append(0x01)
    
    code.append(0x07)
    
    code.extend(struct.pack('<I', 0x000FFFFF))  
    
    with open('test.afton', 'wb') as f:
        f.write(code)
    
    
if __name__ == "__main__":
    create_test_file()

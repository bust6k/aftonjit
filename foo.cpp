#include<iostream>

int foo(char* perms) {
int perms_bit = 0;
int mask = 0x00;
perms_bit |= (perms[0] & 0x40) >> 3;
perms_bit |= (perms[1] & 0x40) >> 4;
perms_bit |= (perms[2] & 0x40) >> 5;
perms_bit |= (perms[3] & 0x40) >> 6;



return perms_bit;
}

int main() {
       char* f = (char*)"rwxp";	
	std::cout << foo(f) << std::endl;
}

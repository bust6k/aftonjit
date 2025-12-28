#include<stdio.h>
#include<sys/mman.h>
#include<string.h>
#include<stdint.h>

// bytecode instructions for JIT compiler
#define PUSH_PRIM 0x00
#define REM_PRIM 0x01
#define DUP 0x02
#define AND 0x03
#define OR 0x04
#define NOT 0x05
#define XOR 0x06
#define RET 0x07
#define CMPEQ 0x08
#define CMPGT 0x09
#define INCLUDESTATIC 0xA
#define INVOKE 0xB
#define CMPTLT 0xC
#define SHL 0xD
#define SHR 0xE
#define DRF 0xF
#define INCLUDENEAR 0x11
#define STORE 0x12
#define LOAD 0x13
#define STOREP 0x14
#define LOADP 0x15
#define DRFS 0x16
// declarations for somwthing(like function declaration)
#define FN 0x1F
#define DECL_PRIM 0x2F
#define DECL_PTR 0x3F
#define DECL_STRUCT 0x4F

// other
#define NON_RET 0xFFFFF

// you know what it is
int* execute_memory;
static FILE* input_file;
int mm_counter;



void  alloc(size_t len){
 execute_memory = mmap(NULL,len,PROT_EXEC | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE,0,0);

 if(execute_memory == NULL)
 {
printf("\e[31mERROR\e[0m allocating memory error");
return;
 }

}

void open_file(char* name,char* rights)
{
input_file = fopen(name,rights); 

if (input_file == NULL)
{
printf("\e[31mERROR\e[0m opening file %s:can't open it",name);
return;

}

}

int read_next_instruction()
{
int ch = fgetc(input_file);

if(ch == EOF)
{
return -1;
}

return ch;
}


void emit_ret(int ret_val)
{
if(ret_val == NON_RET)
{
execute_memory[mm_counter++] = 0xC3; 
return;
}

int8_t mov_inst[] = {0xB8,ret_val,0x00,0x00,0x00};

memcpy(&execute_memory[mm_counter],&mov_inst,5);

mm_counter += 5;

execute_memory[mm_counter++] = 0xC9;
execute_memory[mm_counter++] = 0xC3;
}


void emit_prologue(int loc_cont)
{
execute_memory[mm_counter++] = 0x55;

int8_t mov_inst = {0x48,0x89,0xE5};

memcpy(&execute_memory[mm_counter],&mov_inst,3);

mm_counter +=3;

int8_t sub_inst[] = {0x48,0x83,0xEC,loc_cont*8};

memcpy(&execute_memory[mm_counter],&sub_inst,4);

mm_counter += 4;
}

void emit_pushPrim(int val)
{
execute_memory[mm_counter++] = 0x6A;
execute_memory[mm_counter++] = val;

}

void emit_remPrim()
{
int8_t sub_inst[] = {0x48,0x83,0xEC,8};
memcpy(&execute_memory[mm_counter],&sub_inst,4);
mm_counter += 4;
}


void emit_dup()
{
int8_t  mov_inst[] = {0x49,0x89,0xE0};
memcpy(&execute_memory[mm_counter],&mov_inst,3);
mm_counter += 3;

execute_memory[mm_counter++] = 0x41;
execute_memory[mm_counter++] = 0x50;
}


int code_gen(int inst)
{

switch(inst)
{
	case PUSH_PRIM:
	
	char push_val = read_next_instruction();

	if(push_val == EOF)
	{
	return EOF;
	}
	emit_pushPrim(push_val);

        case REM_PRIM:
	
	emit_remPrim();

	case INVOKE:
	
	case RET:

	char ret_val = read_next_instruction();

	if(ret_val == EOF)
	{
	return EOF;
	}
	emit_ret(ret_val);	

	case DUP:

	emit_dup();
}
}

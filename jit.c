#include<stdio.h>
#include<sys/mman.h>
#include<string.h>
#include<stdint.h>
#include "map.c"

// bytecode instructions for jit compiler
#define PUSH 0x00
#define REM  0x01
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
#define ADD 0x10
#define SUB 0x17
#define MUL 0x18
#define DIV 0x19
// function declaration 
#define FN 0x1F
#define END 0x5F 

// type declaration 
#define DECL_INT 0x2F
#define DECL_CHAR 0x5F
#define DECL_SHORT 0x6F
#define DECL_PTR 0x3F
#define DECL_STRUCT 0x4F

// ret instruction extensions
#define RET_VOID  0xFFFFF // just magic number
#define RET_STACK 0xDEADA // just magic number

// arguments
#define ARG1 0x1A
#define ARG2 0x2A
#define ARG3 0x3A
#define ARG4 0x4A
#define ARG5 0x5A
#define ARG6 0x6A

// the global variables
int* execute_memory;
int* original_memory;
static FILE* input_file;
int mm_counter;
Map* func_table;


void  alloc(size_t len){
 execute_memory = mmap(NULL,len, PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE,0,0);

 if(execute_memory == NULL)
 {
printf("\e[31mERROR\e[0m allocating memory error");
return;
 }

 original_memory = execute_memory;

func_table = make_map();
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
if(ret_val == RET_VOID)
{

int8_t mov_zero_inst[] = {0xB8,0x00,0x00,0x00,0x00};

memcpy(&execute_memory[mm_counter],&mov_zero_inst,5);
mm_counter += 5;

execute_memory[mm_counter++] = 0xC9;
execute_memory[mm_counter++] = 0xC3; 
return;
}

if(ret_val == RET_STACK)
{
execute_memory[mm_counter++] = 0x58;
execute_memory[mm_counter++] = 0xC9;
execute_memory[mm_counter++] = 0xC3;
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

int8_t mov_inst[] = {0x48,0x89,0xE5};

memcpy(&execute_memory[mm_counter],&mov_inst,3);

mm_counter +=3;

int8_t sub_inst[] = {0x48,0x83,0xEC,loc_cont*8};

memcpy(&execute_memory[mm_counter],&sub_inst,4);

mm_counter += 4;
}

void emit_push(int val)
{
execute_memory[mm_counter++] = 0x6A;
execute_memory[mm_counter++] = val;

}

void emit_rem()
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

/*
//TODO: remove this bolierplate and think loops and conditions
void mov_args_to_regs(int args_count)
{

switch(args_count)
{

case 0:

break;

case 1:
{
int8_t  val = (int8_t)fgetc(input_file);
int8_t mov_inst[] = {0xBF,val,0x00,0x00,0x00};
memcpy(&execute_memory[mm_counter],&mov_inst,5);
mm_counter += 5;
break;
}
case 2:
{
  int8_t  val = (int8_t)fgetc(input_file);
  int8_t mov_inst[] = {0xBF,val,0x00,0x00,0x00};
  memcpy(&execute_memory[mm_counter],&mov_inst,5);
  mm_counter += 5;

  int8_t val1 = (int8_t)fgetc(input_file);
  int8_t mov_inst1[] = {0xBE,val1,0x00,0x00,0x00};
  memcpy(&execute_memory[mm_counter],&mov_inst1,5);
  mm_counter += 5;
break;
}
case 3:
{
    int8_t val1 = (int8_t)fgetc(input_file);
    int8_t mov_inst1[] = {0xBF, val1, 0x00, 0x00, 0x00};
    memcpy(&execute_memory[mm_counter], &mov_inst1, 5);
    mm_counter += 5;

    int8_t val2 = (int8_t)fgetc(input_file);
    int8_t mov_inst2[] = {0xBE, val2, 0x00, 0x00, 0x00};
    memcpy(&execute_memory[mm_counter], &mov_inst2, 5);
    mm_counter += 5;

    int8_t val3 = (int8_t)fgetc(input_file);
    int8_t mov_inst3[] = {0xBA, val3, 0x00, 0x00, 0x00};
    memcpy(&execute_memory[mm_counter], &mov_inst3, 5);
    mm_counter += 5;
    break;
}

case 4:
{
    int8_t val1 = (int8_t)fgetc(input_file);
    int8_t mov_inst1[] = {0xBF, val1, 0x00, 0x00, 0x00};
    memcpy(&execute_memory[mm_counter], &mov_inst1, 5);
    mm_counter += 5;

    int8_t val2 = (int8_t)fgetc(input_file);
    int8_t mov_inst2[] = {0xBE, val2, 0x00, 0x00, 0x00};
    memcpy(&execute_memory[mm_counter], &mov_inst2, 5);
    mm_counter += 5;

    int8_t val3 = (int8_t)fgetc(input_file);
    int8_t mov_inst3[] = {0xBA, val3, 0x00, 0x00, 0x00};
    memcpy(&execute_memory[mm_counter], &mov_inst3, 5);
    mm_counter += 5;

    int8_t val4 = (int8_t)fgetc(input_file);
    int8_t mov_inst4[] = {0xB9, val4, 0x00, 0x00, 0x00};
    memcpy(&execute_memory[mm_counter], &mov_inst4, 5);
    mm_counter += 5;
    break;
}

case 5:
{
    int8_t vals[5];
    int8_t opcodes[] = {0xBF, 0xBE, 0xBA, 0xB9, 0x41, 0xB8};

    for (int i = 0; i < 4; i++) {
        vals[i] = (int8_t)fgetc(input_file);
        int8_t mov_inst[] = {opcodes[i], vals[i], 0x00, 0x00, 0x00};
        memcpy(&execute_memory[mm_counter], mov_inst, 5);
        mm_counter += 5;
    }
    vals[4] = (int8_t)fgetc(input_file);
    int8_t mov_r8[] = {0x41, 0xB8, vals[4], 0x00, 0x00, 0x00};
    memcpy(&execute_memory[mm_counter], mov_r8, 6);
    mm_counter += 6;
    break;
}

case 6:
{
    int8_t vals[6];
    int8_t opcodes[6][2] = {
        {0xBF}, {0xBE}, {0xBA}, {0xB9},
        {0x41, 0xB8}, {0x41, 0xB9}
    };

    for (int i = 0; i < 4; i++) {
        vals[i] = (int8_t)fgetc(input_file);
        int8_t mov_inst[] = {opcodes[i][0], vals[i], 0x00, 0x00, 0x00};
        memcpy(&execute_memory[mm_counter], mov_inst, 5);
        mm_counter += 5;
    }
    for (int i = 4; i < 6; i++) {
        vals[i] = (int8_t)fgetc(input_file);
        int8_t mov_inst[] = {opcodes[i][0], opcodes[i][1], vals[i], 0x00, 0x00, 0x00};
        memcpy(&execute_memory[mm_counter], mov_inst, 6);
        mm_counter += 6;
    }
    break;
}
}

}
*/



char* get_name()
{
char* name = NULL;
int i = 33;

int j = 0;

while((i = fgetc(input_file)) != '\0')
{
name[j] = i;
}
return name;
}



int emit_invoke(char* name)
{
char* addr = map_get(func_table,name);

if(addr == NULL)
{
return -2;
}

execute_memory[mm_counter++] = 0xE8;
execute_memory[mm_counter++] = (int)*addr;

return 0;
}


int code_gen_inst(int inst)
{

switch(inst)
{
	case PUSH:
	
	char push_val = read_next_instruction();

	if(push_val == EOF)
	{
	return EOF;
	}
	emit_push(push_val);

        case REM:
	
	emit_rem();

	case INVOKE:
	
	char* n = get_name();
	int r = emit_invoke(n);

	if(r == -2)
	{
	return -2;
	}

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

return 0;
}


void  gen_func_body()
{
int i = 0;


while((i = fgetc(input_file)) != END)
{
//TODO: add if conditions for checking current
// argument and if argument todo something
// and also think how work with arguments 

int r = code_gen_inst(i);

if(r ==EOF)
{
return;
}

}

}

void gen_func(char* name)
{

int* func_addr = execute_memory;

int fn_signature= fgetc(input_file);

if(fn_signature != FN)
{
printf("error: function signature was changed during code executing");
return;
}


int locals_c = fgetc(input_file);

if(locals_c > 100)
{
printf("error: count of local variables cannot be greater than 100");
return;
}

emit_prologue(locals_c);


int args_c = fgetc(input_file);

if(args_c > 6)
{
printf("error: count of arguments cannot be greater than 6");
return;
}

//mov_args_to_regs(args_c)

gen_func_body();


map_put(func_table,name,func_addr);
}



int main(int argc,char* argv[])
{

open_file(argv[1],"r");
}

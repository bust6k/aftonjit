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
#define RET_VOID  0xFF // just magic number
#define RET_STACK 0xDE // just magic number

// arguments
#define ARG1 0x1A
#define ARG2 0x2A
#define ARG3 0x3A
#define ARG4 0x4A
#define ARG5 0x5A
#define ARG6 0x6A

// global things for byte code 
#define END_PRG 0xFE

// the global variables
char* execute_memory;
static FILE* input_file;
int mm_counter;
Map* func_table;
Map* func_len_table;
char* exec_clone;

 int code_gen_inst(int inst);

#ifndef PRODUCT

int len(char* s)
  {
  int l = 0;
  
  while(*s != '\0')
  {
  ++l;
  s++;
 
 if(l >= 255)
  {
  return -2;
  }

  }

  int* len = (int*)map_get(func_len_table,s);

  if(len == NULL)
  {
  map_put(func_len_table,s,&l);
  }

  return l;
  } 

#endif


int check_magic()
{

uint32_t buf[1];

int res = fread(buf,4,1,input_file);

if(res != 1)
{
printf("error happens during reading magic number");
return -1;
}
return 0;
}

int check_version(int byte)
{

if(byte != 1)
{
return -1;
}
return 0;
}

void  alloc(size_t len){
 execute_memory = mmap(NULL,len,PROT_EXEC | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE,0,0);

 if(execute_memory == NULL)
 {
printf("ERROR: allocating memory error \n");
return;
 }

 if(execute_memory == MAP_FAILED)
 {
printf("ERROR: map failed\n");
return;
 }

 exec_clone = execute_memory;

func_table = make_map();
func_len_table = make_map();

}

void open_file(char* name,char* rights)
{
input_file = fopen(name,rights); 

if (input_file == NULL)
{
printf("ERROR: opening file %s:can't open that\n",name);
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

if(ch == 0xFE)
{
return -4;
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

else if(ret_val == RET_STACK)
{
execute_memory[mm_counter++] = 0x58;
execute_memory[mm_counter++] = 0xC9;
execute_memory[mm_counter++] = 0xC3;
return;
}

else
{
int8_t mov_inst[] = {0xB8,ret_val,0x00,0x00,0x00};

memcpy(&execute_memory[mm_counter],&mov_inst,5);

mm_counter += 5;

execute_memory[mm_counter++] = 0xC9;
execute_memory[mm_counter++] = 0xC3;
}
}


void emit_prologue(int loc_cont)
{
execute_memory[mm_counter++] = 0x55;

int8_t mov_inst[] = {0x48,0x89,0xE5};

memcpy(&execute_memory[mm_counter],&mov_inst,3);

mm_counter +=3;

if(loc_cont != 0)
{
int8_t sub_inst[] = {0x48,0x83,0xEC,loc_cont*8};

memcpy(&execute_memory[mm_counter],&sub_inst,4);

mm_counter += 4;
}

}

void emit_push(int val)
{
execute_memory[mm_counter++] = 0x6A;
execute_memory[mm_counter++] = val;

}

void emit_rem()
{
int8_t sub_inst[] = {0x48,0x83,0xC4,8};
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

char* func_addr = execute_memory;

//int fn_signature= fgetc(input_file);
/*
if(fn_signature != FN)
{
printf("error: function signature was changed during code executing\n");
return;
}
*/

int locals_c = fgetc(input_file);

if(locals_c > 100)
{
printf("error: count of local variables cannot be greater than 100\n");
return;
}

emit_prologue(locals_c);


int args_c = fgetc(input_file);

if(args_c > 6)
{
printf("error: count of arguments cannot be greater than 6\n");
return;
}

//mov_args_to_regs(args_c)

gen_func_body();


map_put(func_table,name,func_addr);
}





char* get_name(int len)
{
char* name = malloc(len + 1);
int i = 33;

int j = 0;

while((i = fgetc(input_file)) != '\0')
{
name[j] = i;

j++;

}

name[j] = '\0';
return name;
}

int emit_invoke(char* name)
{
int* addr = map_get(func_table,name);

if(addr == NULL)
{
return -2;
}

uint64_t fun_addr = (uint64_t)addr;

execute_memory[mm_counter++] = 0x49;
execute_memory[mm_counter++] = 0xBB;
memcpy(&execute_memory[mm_counter],&fun_addr,8);
mm_counter +=8;

execute_memory[mm_counter++] = 0x41;
execute_memory[mm_counter++] = 0xFF;
execute_memory[mm_counter++] = 0xD3;
return 0;
}


int code_gen_inst(int inst)
{

switch(inst)
{
	case PUSH:
	{	
	char push_val = read_next_instruction();

	if(push_val == EOF)
	{
	return EOF;
	}
	emit_push(push_val);
	break;
        case REM:
	
	emit_rem();
	break;
        }

	case INVOKE:	
	{
	int len = fgetc(input_file);

	char* n = get_name(len);
	
	int r = emit_invoke(n);

	if(r == -2)
	{
	//free(n);
	return -2;
	}
	free(n);
	break;
        }
	case RET:
	{
	unsigned char ret_val = read_next_instruction();

	if(ret_val == EOF)
	{
	return EOF;
	}
  
	emit_ret(ret_val);	
	break;
        }
	case DUP:
	{
	emit_dup();
	break;
	}
	case FN:
        {	
	
	int name_len = fgetc(input_file);

	char* name = get_name(name_len);

	gen_func(name);

	free(name);
	break;
	}
	case END_PRG:
	{
	return -4;
	}
	
	}
return 0;
}

int main(int argc,char* argv[])
{

open_file(argv[1],"rb");


alloc(4096);

int magic = read_next_instruction();

int res = check_version(magic);

if(res != 0)
{
printf("incorrect byte-code version,expected version %d,got %d:compilation failed\n",1,magic);
return 1;
}

res = check_magic();

if(res != 0)
{
printf("incorrect byte-code format,exepcted magic number 0xFFF :compilation failed\n");
return 1;
}




while(1)
{

int foo = read_next_instruction();


if(foo == -4)
{
break;
}


 int ret_val = code_gen_inst(foo);


if(ret_val == -2 )
{
printf("compilation failed\n");
return 1;
}


}

#ifndef PRODUCT 

FILE* f = fopen("jit_dump.bin", "wb");
fwrite(exec_clone, 1, mm_counter, f);  
fclose(f);
printf("Dumped %d bytes to jit_dump.bin\n", mm_counter);

#endif

if(mprotect(exec_clone,4096,PROT_READ | PROT_EXEC) == -1)
{
printf("ERROR: changing memory rules  is failed\n");
return -1;
}

  int (*func)() = (int(*)())exec_clone;

  func();
  #ifdef PRODUCT
  printf("compilation gone successful\n");
  #endif
  }

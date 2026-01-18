# Introduction
**AftonJIT** - is a jit compiler for afton byte-code that built simple and flexibility,instead llvm. The current AftonJIT version is **0.1** ,the current format version is **1** and its magic number is 0xFFF . Afton V1 supports 5 instructions: 

- push
- rem
- ret
- invoke(without arguments)
- dup

Also it supports functions. But variables not provided in that version,yet. 

Now,AftonJIT as target supports only x86_64.

# How to build

  AftonJIT  has some ways to built it. Here's they:
  
  1. build production version by gcc or tcc:
  ```bash
  make gcc
  ```
  Or
  ```bash
  make tcc
  ```

  2. build debug version by gcc or tcc:
  ```bash
  make gcc_debug
  ```
 Or
  ```bash
  make tcc_debug
  ```
  
  3. Also you may to clean aftonjit binary by:
  ```bash
  make clean
  ``` 

# Opcodes

The next map displays mnemonic and its correspond opcode for writing real afton proggrams:

- push [ANY_NUMBER]  : 0x00
- rem : 0x01
- ret [RET_VOID or RET_STACK or ANY_NUMBER] : 0x07
- invoke [FUNCTION_NAME_LEN] [FUNCTION_NAME] : 0x0B
- dup : 0x02
- fn [FUNCTION_NAME_LEN] [FUNCTION_NAME] [LOCALS_COUNT] [ARGUMENTS_COUNT] : 0x1F
- end : 0x5F
- end_prg : 0xFE

**Here's**:

1. RET_VOID is magic number notificates AftonJIT not return something from function
2. RET_STACK is magic number notificates AftonJIT return the latest value from stack
3. end is marker notificates AftonJIT scope of the current function is ended
4. end_prg is marker notificates AftonJIT the  proggram code is ended

# Tests

For testing something proggrams,you can execute like this:
```bash
python gen_bytecode.py
```

That command generates 4 test files and their names  you may execute with ./aftonjit command

# Dumping AftonJIT binary code

If you're in the debug mode,you may see the title like "Dumped XX bytes to jit_dump.bin". For seeing what AftonJIT generates based on your proggram,use the command below:

```bash
objdump -D -b binary -m i386:x86-64 jit_dump.bin   
```

You're seeing like this:

```asm
jit_dump.bin:     file format binary


Disassembly of section .data:

0000000000000000 <.data>:
   0:	55                   	push   %rbp
   1:	48 89 e5             	mov    %rsp,%rbp
   4:	58                   	pop    %rax
   5:	c9                   	leave
   6:	c3                   	ret

```

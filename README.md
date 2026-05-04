[NOTE: now AftonJIT in refactoring state. Keep in Mind that the information below inactual and now AftonJIT don't works]


# Introduction
**AftonJIT** - is a jit compiler for afton bytecode designed simple and flexibility. The current AftonJIT version is **0.1** ,the current format version is **1** and its magic number is 0xFFF. Afton V1 supports 5 instructions: 

- push
- rem
- ret
- invoke(without arguments)
- dup

Also it supports functions, without arguments and variables 

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
make test
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

# Optimization phase

The first version of AftonJIT,have no serious graph-based optimizations like constant propagations via RPO(DFS). But it have two pretty simple DFA-based optimizations:
- Constant Folding via DFA(DFA made of detect typical constant redudantions and remove them from AftonIR level)
- Dead Code Elimination via DFA(DFA made of same as CF's DFA made)

So,they're doing on IR level,not binary level as of it was.

The AftonIR have of now one serious bug with stack. To dive into, look to the pseudo-code below:
```c
push 111,40
ldr ARG2,S[0]
```

So yes, AftonIR allows to compute literals anonimously. That's a feature,but a raw one,because other AftonJIT's versions assume you know count of variables in function you call. But it don't cover that feature of anonimous literal computing. So then the function use more of stack space rather than it allocated at first,then  a serious exploit occured,just because of Stack Overflow.

anyone Who reads it, if you ask "Why I need that info???!" So I answer calmy,I scare you're thought I leave out the project. So, It hears like Justifying,but i really scare you're conside AftonJIT is a "yet another study JIT". NO. I just had no time,but now when i got it fully, i return to the AftonJIT's developing

CFLAGS_GCC=-Wall -DPRODUCT  -o2 $(FILES) -o aftonjit
CFLAGS_TCC=-Wall -DPRODUCT $(FILES) -o aftonjit
CFLAGS_GCC_DEBUG=-Wall  -o2 $(FILES) -o aftonjit
CFLAGS_TCC_DEBUG=-Wall   $(FILES) -o aftonjit
FILES=jit.c
GCC=gcc
TCC=tcc
QuickJS=qjs
gcc:
	$(GCC) $(CFLAGS_GCC)
tcc:
	$(TCC) $(CFLAGS_TCC)
gcc_debug:
	$(GCC) $(CFLAGS_GCC_DEBUG)
tcc_debug: 
	$(TCC) $(CFLAGS_TCC_DEBUG)
clean:
	rm -f ./aftonjit
test:
	# TODO: tommorow embeding QuickJS into AftonJIT. 
	$(QuickJS) gen_bytecode.js

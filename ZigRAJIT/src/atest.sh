prt "what do you want: 1(compile test and into gdb) or 2(compile and run test)"
read num

if [[ $num == 1 ]];then
	zig test assembler-x86_64.zig -fno-strip --test-no-exec
	PTH=$(ls -t ../.zig-cache/o | head -n1)   
	gdb ../.zig-cache/o/$PTH/test   
elif [[ $num == 2 ]];then
	 zig test assembler-x86_64.zig -fno-strip --test-no-exec
        PTH=$(ls -t ../.zig-cache/o | head -n1)
         ../.zig-cache/o/$PTH/test
else
	prt "unsupported option:" $num
	exit 1
fi

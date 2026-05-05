prt "ATest(AftonTest) is a simple framework made to simply run the AftonJIT's tests"
prt ""
prt "what do you want: 1(compile test and into gdb) or 2(compile and run test)?"
read num
prt "enter the name of a file(or 1 for assembler-x86_64.zig,2 for parse_file.zig):"
read fn




if [[ $num == 1 ]];then
	
	if (( $fn == 1 ));then
		zig test assembler-x86_64.zig -fno-strip --test-no-exec
                PTH=$(ls -t ../.zig-cache/o | head -n1)
               gdb ../.zig-cache/o/$PTH/test
        
        elif (( $fn == 2 ));then
		zig test parse_file.zig -fno-strip --test-no-exec
                PTH=$(ls -t ../.zig-cache/o | head -n1)
                gdb ../.zig-cache/o/$PTH/test

        else
	
	zig test $fn -fno-strip --test-no-exec
	PTH=$(ls -t ../.zig-cache/o | head -n1)   
	gdb ../.zig-cache/o/$PTH/test  
	fi	
fi

if [[ $num == 2 ]];then
	
	if (( $fn == 1 ));then
        zig test assembler-x86_64.zig -fno-strip --test-no-exec
        PTH=$(ls -t ../.zig-cache/o | head -n1)
        ../.zig-cache/o/$PTH/test
        
        elif (( $fn == 2 ));then
	
	zig test parse_file.zig -fno-strip --test-no-exec
        PTH=$(ls -t ../.zig-cache/o | head -n1)
        ../.zig-cache/o/$PTH/test

        else
	
	zig test $fn -fno-strip --test-no-exec
        PTH=$(ls -t ../.zig-cache/o | head -n1)
	../.zig-cache/o/$PTH/test
	fi

else
	prt "unsupported option:" $num
	exit 1
fi

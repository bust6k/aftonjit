/*
let num = 0b00000000000000000000000011111111
console.log(num.toString(16))

let num1 = 0b00000000000000001111111100000000
console.log(num1.toString(16))

let num2 = 0b1111111100000000
console.log(num2.toString(16))

let num3 = 0x58;
console.log(num3.toString(2))
*/
// it's rsp
function align(n,a){
 return (n + (a - 1)) & ~(a - 1);
}

function len(obj){
return obj.length;
}

let num4 = 13 & ~6;
let twelf = 12;
let six = -0b11100;
console.log((twelf.toString(2)))
console.log(six.toString(10))
console.log(align(7,8))
console.log((1700 * 75) / 2)
let f = 0xF
let foo = 0b00100000
let lifter = 0b11100000
let fof = 0b11110000
let big = 0b11111111111111111111111111111111
console.log("real FOO:",foo.toString(16))
console.log("FOOOFOFO, so:",lifter.toString(16))
console.log("so it's gone,stub:",fof.toString(16))
console.log(big.toString(16))
/*
// it's rbp
let num5 = 0b101
console.log(num5.toString(10))
*/

/*
  perms_bit |= (perms[0].charCodeAt(0) & 0x40) >> 3;
  perms_bit |= (perms[1].charCodeAt(0) & 0x40) >> 4;
  perms_bit |= (perms[2].charCodeAt(0) & 0x40) >> 5;
  perms_bit |= (perms[3].charCodeAt(0) & 0x40) >> 6;

*/

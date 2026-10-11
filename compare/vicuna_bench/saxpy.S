    .text
    .global main
main:
    la a0, src1
    la a1, src2
    la a2, dst
    li a3, AVL
    li a4, 3
1:  vsetvli t0, a3, e32, m8, ta, ma
    vle32.v v8, (a0)
    vle32.v v16, (a1)
    vmul.vx v8, v8, a4
    vadd.vv v8, v8, v16
    vse32.v v8, (a2)
    slli t1, t0, 2
    add a0, a0, t1
    add a1, a1, t1
    add a2, a2, t1
    sub a3, a3, t0
    bnez a3, 1b
    jr x0
    .data
    .align 4
src1: .skip 16384
src2: .skip 16384
dst:  .skip 16384

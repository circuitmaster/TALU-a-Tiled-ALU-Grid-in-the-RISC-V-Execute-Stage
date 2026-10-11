    .text
    .global main
main:
    li a3, AVL
    vsetvli t0, a3, e32, m8, ta, ma
    vmv.s.x v24, x0
    la a0, src1
1:  vsetvli t0, a3, e32, m8, ta, ma
    vle32.v v8, (a0)
    vredsum.vs v24, v8, v24
    slli t1, t0, 2
    add a0, a0, t1
    sub a3, a3, t0
    bnez a3, 1b
    vmv.x.s t1, v24
    srai t1, t1, 10
    jr x0
    .data
    .align 4
src1: .skip 16384

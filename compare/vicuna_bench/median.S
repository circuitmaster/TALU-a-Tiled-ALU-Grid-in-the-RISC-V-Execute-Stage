    .text
    .global main
main:
    la a0, src1
    la a2, dst
    li a3, AVL
1:  vsetvli t0, a3, e32, m8, ta, ma
    vle32.v v8, (a0)
    addi t1, a0, 4
    vle32.v v16, (t1)
    addi t1, a0, 8
    vle32.v v24, (t1)
    vmin.vv v0, v8, v16
    vmax.vv v8, v8, v16
    vmin.vv v8, v8, v24
    vmax.vv v0, v0, v8
    vse32.v v0, (a2)
    slli t1, t0, 2
    add a0, a0, t1
    add a2, a2, t1
    sub a3, a3, t0
    bnez a3, 1b
    jr x0
    .data
    .align 4
src1: .skip 16384
dst:  .skip 16384

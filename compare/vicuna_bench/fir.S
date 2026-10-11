    .text
    .global main
main:
    la a0, src1
    la a2, dst
    li a3, AVL
    li t2, 2
    li t3, 3
    li t4, 1
1:  vsetvli t0, a3, e32, m8, ta, ma
    vle32.v v8, (a0)
    vmul.vx v0, v8, t2
    addi t1, a0, 4
    vle32.v v8, (t1)
    vmacc.vx v0, t3, v8
    addi t1, a0, 8
    vle32.v v8, (t1)
    vmacc.vx v0, t4, v8
    addi t1, a0, 12
    vle32.v v8, (t1)
    vmacc.vx v0, t2, v8
    addi t1, a0, 16
    vle32.v v8, (t1)
    vmacc.vx v0, t4, v8
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

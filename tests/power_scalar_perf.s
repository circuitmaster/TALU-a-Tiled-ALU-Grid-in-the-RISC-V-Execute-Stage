# power_scalar_perf.s -- (a+b)^8 for 1024 elements, scalar RV32IM loop.
#   Same work as power_grid_perf.s, executed as a dependent instruction chain:
#   per element = add + 3 mul (square three times) + 2 loads + store + loop ctrl.
    addi x5, x0, 0          # src1 ptr
    lui  x6, 1              # src2 ptr = 4096
    lui  x7, 2              # dst ptr  = 8192
    addi x9, x0, 1024       # element count
    addi x10, x0, 0         # index
loop:
    lw   x11, 0(x5)         # a
    lw   x12, 0(x6)         # b
    add  x13, x11, x12      # s = a + b
    mul  x13, x13, x13      # s^2
    mul  x13, x13, x13      # s^4
    mul  x13, x13, x13      # s^8
    sw   x13, 0(x7)
    addi x5, x5, 4
    addi x6, x6, 4
    addi x7, x7, 4
    addi x10, x10, 1
    blt  x10, x9, loop
    ecall

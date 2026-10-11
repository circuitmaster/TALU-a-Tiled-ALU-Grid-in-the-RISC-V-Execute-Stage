# scalar1.s -- RV32I smoke test: arithmetic, store/load, forwarding, branch loop
    addi x1, x0, 10        # x1 = 10
    addi x2, x0, 20        # x2 = 20
    add  x3, x1, x2        # x3 = 30
    sub  x4, x2, x1        # x4 = 10
    slli x5, x1, 2         # x5 = 40
    xori x12, x1, -1       # x12 = ~10 = 0xFFFFFFF5
    and  x13, x3, x5       # x13 = 30 & 40 = 8
    addi x6, x0, 0         # base address 0
    sw   x3, 0(x6)         # mem[0] = 30
    lw   x7, 0(x6)         # x7 = 30  (load)
    add  x8, x7, x1        # x8 = 40  (load-use hazard on x7)
    # sum 1..5 in x9
    addi x9, x0, 0         # acc = 0
    addi x10, x0, 1        # i = 1
    addi x11, x0, 6        # limit = 6
loop:
    add  x9, x9, x10       # acc += i
    addi x10, x10, 1       # i++
    blt  x10, x11, loop    # while i < 6
    sw   x9, 4(x6)         # mem[1] = 15
    ecall

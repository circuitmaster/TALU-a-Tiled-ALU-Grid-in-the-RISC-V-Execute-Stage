# stream_dot_small.s -- streaming dot product, 2 blocks (8 elements)
#   src1 @ 0, src2 @ 32, dst @ 64, count = 2 blocks, mode = 1 (accumulate)
#   grid: col0 = MUL (4 products); diagonal SW chain reduces the 4 products to
#   one sum at corner (0,3) which drains; the engine accumulates across blocks.
    addi x5, x0, 0          # src1 base
    addi x6, x0, 32         # src2 base
    addi x7, x0, 64         # dst base (scalar result)
    addi x8, x0, 2          # block count
    # column 0: element-wise multiply
    gcfg 0,0, mul, W,W, 0
    gcfg 1,0, mul, W,W, 0
    gcfg 2,0, mul, W,W, 0
    gcfg 3,0, mul, W,W, 0
    # carry products forward along their rows
    gcfg 0,1, copya, W,W, 0
    gcfg 0,2, copya, W,W, 0
    gcfg 1,1, copya, W,W, 0
    # diagonal reduction (W + SW) collapsing to corner (0,3)
    gcfg 2,1, add, W,SW, 0   # p2+p3
    gcfg 1,2, add, W,SW, 0   # p1+(p2+p3)
    gcfg 0,3, add, W,SW, 1   # p0+... -> drain, accumulate
    gflow x5, x6, x7, x8, 1  # accumulate mode
    ecall

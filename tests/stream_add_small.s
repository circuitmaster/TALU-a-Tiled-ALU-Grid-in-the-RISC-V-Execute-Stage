# stream_add_small.s -- streaming element-wise add, 4 blocks (16 elements)
#   src1 @ 0, src2 @ 64, dst @ 128, count = 4 blocks
#   grid: col0 = ADD with drain on every row (latency 1) -> N adds/cycle
    addi x5, x0, 0          # src1 base (bytes)
    addi x6, x0, 64         # src2 base
    addi x7, x0, 128        # dst base
    addi x8, x0, 4          # block count
    gcfg 0,0, add, W,W, 1
    gcfg 1,0, add, W,W, 1
    gcfg 2,0, add, W,W, 1
    gcfg 3,0, add, W,W, 1
    gflow x5, x6, x7, x8, 0 # stream add  (mode 0)
    ecall

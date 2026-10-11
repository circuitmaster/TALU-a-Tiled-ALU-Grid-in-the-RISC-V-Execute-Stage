# stream_dot_perf.s -- dot product of 1024 elements (256 blocks of N=4)
#   src1 @ 0, src2 @ 4096, dst @ 8192 (scalar), count = 256, accumulate mode
    addi x5, x0, 0
    lui  x6, 1              # src2 base = 4096
    lui  x7, 2              # dst  base = 8192
    addi x8, x0, 256        # 256 blocks * 4 = 1024 elements
    gcfg 0,0, mul, W,W, 0
    gcfg 1,0, mul, W,W, 0
    gcfg 2,0, mul, W,W, 0
    gcfg 3,0, mul, W,W, 0
    gcfg 0,1, copya, W,W, 0
    gcfg 0,2, copya, W,W, 0
    gcfg 1,1, copya, W,W, 0
    gcfg 2,1, add, W,SW, 0
    gcfg 1,2, add, W,SW, 0
    gcfg 0,3, add, W,SW, 1
    gflow x5, x6, x7, x8, 1
    ecall

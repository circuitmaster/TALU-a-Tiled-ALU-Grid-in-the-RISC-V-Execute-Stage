# stream_add_perf.s -- element-wise add of 1024 elements (256 blocks of N=4)
#   src1 @ 0, src2 @ 4096, dst @ 8192, count = 256
    addi x5, x0, 0
    lui  x6, 1              # src2 base = 4096
    lui  x7, 2              # dst  base = 8192
    addi x8, x0, 256        # 256 blocks * 4 = 1024 elements
    gcfg 0,0, add, W,W, 1
    gcfg 1,0, add, W,W, 1
    gcfg 2,0, add, W,W, 1
    gcfg 3,0, add, W,W, 1
    gflow x5, x6, x7, x8, 0
    ecall

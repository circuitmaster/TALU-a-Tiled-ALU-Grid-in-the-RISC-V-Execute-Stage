# power_grid_perf.s -- (a+b)^8 for 1024 elements, spatial path, 4 rows in parallel
#   src1 @ 0, src2 @ 4096, dst @ 8192, count = 256 blocks
    addi x5, x0, 0
    lui  x6, 1
    lui  x7, 2
    addi x8, x0, 256
    gcfg 0,0, add, W,W, 0
    gcfg 1,0, add, W,W, 0
    gcfg 2,0, add, W,W, 0
    gcfg 3,0, add, W,W, 0
    gcfg 0,1, mul, W,W, 0
    gcfg 1,1, mul, W,W, 0
    gcfg 2,1, mul, W,W, 0
    gcfg 3,1, mul, W,W, 0
    gcfg 0,2, mul, W,W, 0
    gcfg 1,2, mul, W,W, 0
    gcfg 2,2, mul, W,W, 0
    gcfg 3,2, mul, W,W, 0
    gcfg 0,3, mul, W,W, 1
    gcfg 1,3, mul, W,W, 1
    gcfg 2,3, mul, W,W, 1
    gcfg 3,3, mul, W,W, 1
    gflow x5, x6, x7, x8, 0
    ecall

    addi x5,x0,0
    addi x6,x0,0
    addi x7,x0,64
    addi x8,x0,2
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
    gflow x5, x5, x7, x8, 1
    ecall

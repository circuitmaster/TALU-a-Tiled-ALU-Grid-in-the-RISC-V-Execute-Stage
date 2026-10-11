    addi x5,x0,0
    addi x6,x0,32
    addi x7,x0,64
    addi x8,x0,2
    gcfg 0,0, mul, W,W, 1
    gcfg 1,0, mul, W,W, 1
    gcfg 2,0, mul, W,W, 1
    gcfg 3,0, mul, W,W, 1
    gflow x5, x6, x7, x8, 0
    ecall

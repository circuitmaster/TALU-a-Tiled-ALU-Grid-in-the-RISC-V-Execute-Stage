# power_grid_small.s -- (a+b)^8 along a spatial path, all 4 rows in parallel.
#   row r: col0 ADD(a,b)=s ; col1 MUL=s^2 ; col2 MUL=s^4 ; col3 MUL=s^8 (drain)
#   src1 @ 0, src2 @ 16, dst @ 32, count = 1 block (4 elements)
    addi x5, x0, 0
    addi x6, x0, 16
    addi x7, x0, 32
    addi x8, x0, 1
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

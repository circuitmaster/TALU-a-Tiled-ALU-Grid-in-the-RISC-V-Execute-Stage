# stream_fir_small.s -- 5-tap FIR y[i] = sum_k h[k]*x[i+k], h = [2,3,1,2,1]
#   x @0 (8 elements, x[8..] = 0), acc/y @64 (word 16), 2 blocks of N=4
#   One streaming pass per tap: acc = h_k * x[i+k] + acc  (acc starts at 0).
#   Grid: col0 MUL(W, C=h_k); col1 ADD(W, E=acc); COPYA chain -> col-3 drain.
    addi x7, x0, 64         # acc/y base
    addi x8, x0, 2          # blocks
    # static grid shape (consts rewritten per pass)
    gcfg 0,0, mul, W,C, 0
    gcfg 1,0, mul, W,C, 0
    gcfg 2,0, mul, W,C, 0
    gcfg 3,0, mul, W,C, 0
    gcfg 0,1, add, W,E, 0
    gcfg 1,1, add, W,E, 0
    gcfg 2,1, add, W,E, 0
    gcfg 3,1, add, W,E, 0
    gcfg 0,2, copya, W,W, 0
    gcfg 1,2, copya, W,W, 0
    gcfg 2,2, copya, W,W, 0
    gcfg 3,2, copya, W,W, 0
    gcfg 0,3, copya, W,W, 1
    gcfg 1,3, copya, W,W, 1
    gcfg 2,3, copya, W,W, 1
    gcfg 3,3, copya, W,W, 1
    # pass 0: h0 = 2, x offset 0
    addi x5, x0, 0
    addi x9, x0, 2
    gcfgi 0,0, x9
    gcfgi 1,0, x9
    gcfgi 2,0, x9
    gcfgi 3,0, x9
    gflow x5, x7, x7, x8, 0
    # pass 1: h1 = 3, x offset 4
    addi x5, x0, 4
    addi x9, x0, 3
    gcfgi 0,0, x9
    gcfgi 1,0, x9
    gcfgi 2,0, x9
    gcfgi 3,0, x9
    gflow x5, x7, x7, x8, 0
    # pass 2: h2 = 1, x offset 8
    addi x5, x0, 8
    addi x9, x0, 1
    gcfgi 0,0, x9
    gcfgi 1,0, x9
    gcfgi 2,0, x9
    gcfgi 3,0, x9
    gflow x5, x7, x7, x8, 0
    # pass 3: h3 = 2, x offset 12
    addi x5, x0, 12
    addi x9, x0, 2
    gcfgi 0,0, x9
    gcfgi 1,0, x9
    gcfgi 2,0, x9
    gcfgi 3,0, x9
    gflow x5, x7, x7, x8, 0
    # pass 4: h4 = 1, x offset 16
    addi x5, x0, 16
    addi x9, x0, 1
    gcfgi 0,0, x9
    gcfgi 1,0, x9
    gcfgi 2,0, x9
    gcfgi 3,0, x9
    gflow x5, x7, x7, x8, 0
    ecall

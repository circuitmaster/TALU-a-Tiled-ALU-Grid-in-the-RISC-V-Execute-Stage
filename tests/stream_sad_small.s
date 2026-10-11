# stream_sad_small.s -- SAD (motion estimation kernel): sum |a[i]-b[i]|
#   Identity: sum|a-b| = sum max(a,b) - sum min(a,b)  -> two reduce passes.
#   a @0 (8 el), b @32 (word 8); smax @64 (word 16), smin @68 (word 17),
#   SAD @72 (word 18)
    addi x5, x0, 0          # a
    addi x6, x0, 32         # b
    addi x7, x0, 64         # smax
    addi x8, x0, 2          # blocks
    # reduction tree (same shape as dot): diagonal W+SW collapse to (0,3)
    gcfg 0,1, copya, W,W, 0
    gcfg 0,2, copya, W,W, 0
    gcfg 1,1, copya, W,W, 0
    gcfg 2,1, add, W,SW, 0
    gcfg 1,2, add, W,SW, 0
    gcfg 0,3, add, W,SW, 1
    # pass 1: smax = sum max(a,b)
    gcfg 0,0, max, W,W, 0
    gcfg 1,0, max, W,W, 0
    gcfg 2,0, max, W,W, 0
    gcfg 3,0, max, W,W, 0
    gflow x5, x6, x7, x8, 1
    # pass 2: smin = sum min(a,b)
    addi x7, x0, 68
    gcfg 0,0, min, W,W, 0
    gcfg 1,0, min, W,W, 0
    gcfg 2,0, min, W,W, 0
    gcfg 3,0, min, W,W, 0
    gflow x5, x6, x7, x8, 1
    # SAD = smax - smin
    lw   x20, 64(x0)
    lw   x21, 68(x0)
    sub  x22, x20, x21
    sw   x22, 72(x0)
    ecall

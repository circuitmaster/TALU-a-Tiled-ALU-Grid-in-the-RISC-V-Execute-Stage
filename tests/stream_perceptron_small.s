# stream_perceptron_small.s -- perceptron inference: y = step(w.x + b)
#   Dot-product streaming pass (reduce/accumulate) + scalar bias/threshold.
#   w @0 (8 el = [1..8]), x @32 (word 8, = [1..8]) -> w.x = 204
#   b = -200 -> s = 4 -> y = 1.   s @64 (word 16), y @68 (word 17)
    addi x5, x0, 0          # w
    addi x6, x0, 32         # x
    addi x7, x0, 64         # s
    addi x8, x0, 2          # blocks
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
    # scalar epilogue: s += b ; y = (s > 0)
    lw   x20, 64(x0)
    addi x20, x20, -200
    slt  x21, x0, x20
    sw   x20, 64(x0)
    sw   x21, 68(x0)
    ecall

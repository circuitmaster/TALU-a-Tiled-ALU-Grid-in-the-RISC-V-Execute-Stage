# stream_saxpy_small.s -- z = a*x + y (a=3), 8 elements, single streaming pass
#   x @0, y @32 (word 8), z @64 (word 16), 2 blocks of N=4
#   Uses the constant-operand extension: col0 MUL(W, C=a), col1 ADD(W, E=y),
#   COPYA chain to the col-3 perimeter drain (interior tiles cannot drain).
    addi x5, x0, 0          # x base
    addi x6, x0, 32         # y base
    addi x7, x0, 64         # z base
    addi x8, x0, 2          # blocks
    addi x9, x0, 3          # a
    gcfgi 0,0, x9
    gcfgi 1,0, x9
    gcfgi 2,0, x9
    gcfgi 3,0, x9
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
    gflow x5, x6, x7, x8, 0
    ecall

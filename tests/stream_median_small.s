# stream_median_small.s -- 3-wide median filter y[i] = median(x[i],x[i+1],x[i+2])
#   median3(a,b,c) = max( min(a,b), min( max(a,b), c ) )   -- min/max network
#   x @0 (8 elements, x[8..] = 0). Four streaming passes over shifted streams:
#     t = min(x[i], x[i+1])   u = max(x[i], x[i+1])
#     v = min(u, x[i+2])      y = max(t, v)
#   t @128 (word 32), u @160 (word 40), v @192 (word 48), y @224 (word 56)
    addi x8, x0, 2          # blocks
    addi x5, x0, 0          # x
    addi x6, x0, 4          # x+1
    addi x7, x0, 128        # t
    # pass 1: t = min(x, x+1)   (elementwise 2-stream op drains at col 0)
    gcfg 0,0, min, W,W, 1
    gcfg 1,0, min, W,W, 1
    gcfg 2,0, min, W,W, 1
    gcfg 3,0, min, W,W, 1
    gflow x5, x6, x7, x8, 0
    # pass 2: u = max(x, x+1)
    addi x7, x0, 160        # u
    gcfg 0,0, max, W,W, 1
    gcfg 1,0, max, W,W, 1
    gcfg 2,0, max, W,W, 1
    gcfg 3,0, max, W,W, 1
    gflow x5, x6, x7, x8, 0
    # pass 3: v = min(u, x+2)
    addi x5, x0, 160        # u
    addi x6, x0, 8          # x+2
    addi x7, x0, 192        # v
    gcfg 0,0, min, W,W, 1
    gcfg 1,0, min, W,W, 1
    gcfg 2,0, min, W,W, 1
    gcfg 3,0, min, W,W, 1
    gflow x5, x6, x7, x8, 0
    # pass 4: y = max(t, v)
    addi x5, x0, 128        # t
    addi x6, x0, 192        # v
    addi x7, x0, 224        # y
    gcfg 0,0, max, W,W, 1
    gcfg 1,0, max, W,W, 1
    gcfg 2,0, max, W,W, 1
    gcfg 3,0, max, W,W, 1
    gflow x5, x6, x7, x8, 0
    ecall

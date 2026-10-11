# grid1.s -- multi-path vector add through the ALU grid.
#   v1 = [1,2,3,4]   v2 = [10,20,30,40]   (loaded from data memory)
#   grid: each row r computes (a+b) at col0 then passes COPYA to col3, drains.
#   GSTART feeds v1->A, v2->B, len=4, lanes=1111  => v3 = [11,22,33,44]
#   VSW stores v3 back to mem words 8..11
    addi x1, x0, 0
    vlw  v1, 0(x1)          # v1 <- mem[0..3]
    vlw  v2, 16(x1)         # v2 <- mem[4..7]

    # --- configure the grid: 4 rows, each col0=ADD then COPYA to the edge ---
    gcfg 0,0, add,   W,W, 0
    gcfg 0,1, copya, W,W, 0
    gcfg 0,2, copya, W,W, 0
    gcfg 0,3, copya, W,W, 1
    gcfg 1,0, add,   W,W, 0
    gcfg 1,1, copya, W,W, 0
    gcfg 1,2, copya, W,W, 0
    gcfg 1,3, copya, W,W, 1
    gcfg 2,0, add,   W,W, 0
    gcfg 2,1, copya, W,W, 0
    gcfg 2,2, copya, W,W, 0
    gcfg 2,3, copya, W,W, 1
    gcfg 3,0, add,   W,W, 0
    gcfg 3,1, copya, W,W, 0
    gcfg 3,2, copya, W,W, 0
    gcfg 3,3, copya, W,W, 1

    gstart v3, v1, v2, 4, 0xF   # run grid, drain -> v3
    vsw    v3, 32(x1)           # store v3 -> mem[8..11]
    ecall

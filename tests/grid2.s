# grid2.s -- single non-backward path with vertical routing (scenario 2).
#   a=100 (v1[0]), b=7 (v2[0]), c=5 (v1[1])
#   row0: (0,0)=a+b ; (0,1)=West-South = (a+b) - c ; pass to edge (0,3) drain
#   row1: (1,0),(1,1)=COPYA carry c so that South of (0,1) = c
#   only lane 0 active  => v3[0] = a + b - c = 102
    addi x1, x0, 0
    vlw  v1, 0(x1)             # v1 = [100, 5, 0, 0]
    vlw  v2, 16(x1)            # v2 = [7, 0, 0, 0]

    gcfg 0,0, add,   W,W, 0    # a + b
    gcfg 0,1, sub,   W,S, 0    # (a+b) - South(c)
    gcfg 0,2, copya, W,W, 0
    gcfg 0,3, copya, W,W, 1    # drain -> lane 0
    gcfg 1,0, copya, W,W, 0    # carry c
    gcfg 1,1, copya, W,W, 0    # c sits at reg[1][1] = South of (0,1)

    gstart v3, v1, v2, 6, 0x1  # len 6 (let the path settle), lane 0 only
    vsw    v3, 32(x1)          # mem[8] = result
    ecall

# grid3.s -- vertical reduction down column 0 (up/down dataflow demo).
#   v1 = [1,2,3,4] injected on column-0 West feeds (lanes 0..3).
#   Each tile adds its West operand to the partial sum coming from the South:
#     (3,0)=a3 ; (2,0)=a2+S ; (1,0)=a1+S ; (0,0)=a0+S  -> total at corner (0,0)
#   (0,0) is on the input-column edge, so it drains directly -> v3[0] = 1+2+3+4 = 10
    addi x1, x0, 0
    vlw  v1, 0(x1)            # v1 = [1,2,3,4]

    gcfg 3,0, copya, W,W, 0   # a3
    gcfg 2,0, add,   W,S, 0   # a2 + (a3)
    gcfg 1,0, add,   W,S, 0   # a1 + (a2+a3)
    gcfg 0,0, add,   W,S, 1   # a0 + (a1+a2+a3) -> drain lane 0

    gstart v3, v1, v1, 5, 0x1 # vs2 unused; len 5; lane 0 only
    vsw    v3, 32(x1)         # mem[8] = sum
    ecall

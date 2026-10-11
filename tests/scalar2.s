# scalar2.s -- jumps, LUI/AUIPC, JAL/JALR call, branch variants
    lui  x1, 0x12345        # x1 = 0x12345000
    addi x1, x1, 0x678      # x1 = 0x12345678
    auipc x2, 0             # x2 = pc(of this instr) = 8
    # call a "function" that returns x10 = x11 + x12
    addi x11, x0, 100
    addi x12, x0, 23
    jal  x5, func           # x5 = return addr; jump to func
    addi x20, x0, 1         # marker: executed after return
    j    done
func:
    add  x10, x11, x12      # x10 = 123
    jalr x0, 0(x5)          # return
done:
    # branch variants -> set flags in x21..x24
    addi x21, x0, 0
    addi x22, x0, 0
    bltu x0, x11, l1        # 0 <u 100 -> taken
    addi x21, x0, 99        # skipped
l1: addi x21, x21, 7        # x21 = 7
    bge  x12, x11, l2       # 23 >= 100 ? no -> not taken
    addi x22, x0, 5         # executed -> x22=5
l2: ecall

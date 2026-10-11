#!/usr/bin/env python3
"""TALU assembler: RV32I subset + custom grid/vector extension -> $readmemh image.

Usage:  asm.py input.s -o output.hex
Output: one 8-hex-digit word per line (little-endian word order = PC/4 index).

Custom mnemonics:
  gcfg  row, col, ALUOP, srcA, srcB, drain     # configure one grid tile
  gcfgi row, col, rs                           # tile const := scalar reg value
  gstart vD, vS1, vS2, len, lanes              # run grid; feed/collect vregs
  vlw   vD, imm(rsX)                           # wide vector load
  vsw   vS, imm(rsX)                           # wide vector store
ALUOP in {add,sub,sll,slt,sltu,xor,srl,sra,or,and,copya,copyb,mul,min,max,nop}
srcA/srcB in {W,N,S,NW,SW,C,E}  (C = tile const, E = EXTB stream-B bus)
lanes is a 4-bit mask (e.g. 0x1, 0b0011)
"""
import sys, re

ALU = dict(add=0,sub=1,sll=2,slt=3,sltu=4,xor=5,srl=6,sra=7,**{'or':8,'and':9},
           copya=10,copyb=11,mul=12,**{'min':13,'max':14},nop=31)
SRC = dict(W=0,N=1,S=2,NW=3,SW=4,C=5,E=6)   # C = tile const, E = EXTB bus
OP_C0, OP_C1 = 0x0B, 0x2B

def reg(t):
    t = t.strip().lower()
    if t.startswith('x'): return int(t[1:])
    abi = dict(zero=0,ra=1,sp=2,gp=3,tp=4,t0=5,t1=6,t2=7,s0=8,fp=8,s1=9,
               a0=10,a1=11,a2=12,a3=13,a4=14,a5=15,a6=16,a7=17,
               s2=18,s3=19,s4=20,s5=21,s6=22,s7=23,s8=24,s9=25,s10=26,s11=27,
               t3=28,t4=29,t5=30,t6=31)
    if t in abi: return abi[t]
    raise ValueError(f"bad register {t}")

def vreg(t):
    t = t.strip().lower()
    if t.startswith('v'): return int(t[1:])
    return int(t,0)

def imm(t, labels=None, pc=None, rel=False):
    t = t.strip()
    if labels is not None and t in labels:
        return labels[t]-pc if rel else labels[t]
    return int(t,0)

def u32(x): return x & 0xFFFFFFFF

# encoders ------------------------------------------------------------------
def R(f7,rs2,rs1,f3,rd,op): return u32((f7<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op)
def I(im,rs1,f3,rd,op):     return u32(((im&0xFFF)<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op)
def S(im,rs2,rs1,f3,op):
    im&=0xFFF
    return u32(((im>>5)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|((im&0x1F)<<7)|op)
def B(im,rs2,rs1,f3,op):
    im&=0x1FFF
    return u32((((im>>12)&1)<<31)|(((im>>5)&0x3F)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|
               (((im>>1)&0xF)<<8)|(((im>>11)&1)<<7)|op)
def U(im,rd,op):            return u32(((im&0xFFFFF)<<12)|(rd<<7)|op)
def J(im,rd,op):
    im&=0x1FFFFF
    return u32((((im>>20)&1)<<31)|(((im>>1)&0x3FF)<<21)|(((im>>11)&1)<<20)|
               (((im>>12)&0xFF)<<12)|(rd<<7)|op)

RTYPE={'add':(0,0),'sub':(0x20,0),'sll':(0,1),'slt':(0,2),'sltu':(0,3),
       'xor':(0,4),'srl':(0,5),'sra':(0x20,5),'or':(0,6),'and':(0,7),
       'mul':(0x01,0)}  # RV32M MUL
ITYPE={'addi':0,'slti':2,'sltiu':3,'xori':4,'ori':6,'andi':7}  # f3
SHIFT={'slli':(0,1),'srli':(0,5),'srai':(0x20,5)}
LOAD ={'lb':0,'lh':1,'lw':2,'lbu':4,'lhu':5}
STORE={'sb':0,'sh':1,'sw':2}
BR   ={'beq':0,'bne':1,'blt':4,'bge':5,'bltu':6,'bgeu':7}

MEMRE=re.compile(r'(-?\w+)\s*\(\s*(\w+)\s*\)')

def split_ops(s):
    return [x.strip() for x in s.split(',')] if s.strip() else []

def assemble(lines):
    # pass 1: labels
    labels, pc, prog = {}, 0, []
    for raw in lines:
        line = raw.split('#')[0].split('//')[0].strip()
        if not line: continue
        while ':' in line:
            lbl,_,rest = line.partition(':')
            labels[lbl.strip()] = pc
            line = rest.strip()
            if not line: break
        if not line: continue
        prog.append((pc,line)); pc += 4
    # pass 2: hazard check, then encode
    if not getattr(assemble, "skip_hazard_check", False):
        errs, warns = check_gflow_hazards(prog, labels)
        for w in warns:
            sys.stderr.write("asm.py: warning: GFLOW operand hazard\n" + w + "\n")
        if errs:
            raise ValueError(
                "GFLOW operand hazard -- operands are read in ID without "
                f"forwarding, so a write must precede the gflow by at least "
                f"{GFLOW_HAZARD_DIST} instructions:\n" + "\n".join(errs) +
                "\n  Fix: move the scalar setup earlier, or insert nop(s). "
                "Use --no-hazard-check to override.")
    words=[]
    for pc,line in prog:
        m = re.match(r'(\S+)\s*(.*)', line)
        op = m.group(1).lower(); ops = split_ops(m.group(2))
        words.append(enc(op,ops,labels,pc))
    return words

def enc(op,ops,labels,pc):
    if op in RTYPE:
        f7,f3=RTYPE[op]; return R(f7,reg(ops[2]),reg(ops[1]),f3,reg(ops[0]),0x33)
    if op in ITYPE:
        return I(imm(ops[2]),reg(ops[1]),ITYPE[op],reg(ops[0]),0x13)
    if op in SHIFT:
        f7,f3=SHIFT[op]; return I((f7<<5)|(imm(ops[2])&0x1F),reg(ops[1]),f3,reg(ops[0]),0x13)
    if op in LOAD:
        mm=MEMRE.match(ops[1]); return I(imm(mm.group(1)),reg(mm.group(2)),LOAD[op],reg(ops[0]),0x03)
    if op in STORE:
        mm=MEMRE.match(ops[1]); return S(imm(mm.group(1)),reg(ops[0]),reg(mm.group(2)),STORE[op],0x23)
    if op in BR:
        return B(imm(ops[2],labels,pc,rel=True),reg(ops[1]),reg(ops[0]),BR[op],0x63)
    if op=='lui':   return U(imm(ops[1]),reg(ops[0]),0x37)
    if op=='auipc': return U(imm(ops[1]),reg(ops[0]),0x17)
    if op=='jal':
        if len(ops)==1: rd,tgt=1,ops[0]
        else: rd,tgt=reg(ops[0]),ops[1]
        return J(imm(tgt,labels,pc,rel=True),rd,0x6F)
    if op=='jalr':
        mm=MEMRE.match(ops[1]) if len(ops)>1 and '(' in ops[1] else None
        if mm: return I(imm(mm.group(1)),reg(mm.group(2)),0,reg(ops[0]),0x67)
        return I(imm(ops[2]) if len(ops)>2 else 0,reg(ops[1]),0,reg(ops[0]),0x67)
    if op=='ecall': return 0x00000073
    if op=='nop':   return 0x00000013
    if op=='mv':    return I(0,reg(ops[1]),0,reg(ops[0]),0x13)
    if op=='li':
        v=imm(ops[1]); rd=reg(ops[0])
        if -2048<=v<2048: return I(v,0,0,rd,0x13)
        # lui+addi handled as two words? we only return one; require small li
        raise ValueError("li only supports 12-bit immediates; use lui+addi")
    if op=='j':     return J(imm(ops[0],labels,pc,rel=True),0,0x6F)
    # ---- custom ----
    if op=='gcfg':
        row,col=int(ops[0],0),int(ops[1],0)
        aop=ALU[ops[2].lower()]; sa=SRC[ops[3].upper()]; sb=SRC[ops[4].upper()]; dr=int(ops[5],0)&1
        # row[18:16] col[21:19] op[26:22] srcA[29:27](3b) srcB[10:8](3b) drain[7]
        return u32(OP_C0|(0<<12)|(row<<16)|(col<<19)|(aop<<22)|(sa<<27)|(sb<<8)|(dr<<7))
    if op=='gcfgi':
        # gcfgi row, col, rs   (tile const := rs value)
        # row[9:7] col[24:22] rs1[19:15], funct3=010
        row,col=int(ops[0],0),int(ops[1],0); rs=reg(ops[2])
        return u32(OP_C0|(2<<12)|(row<<7)|(col<<22)|(rs<<15))
    if op=='gstart':
        vd,vs1,vs2=vreg(ops[0]),vreg(ops[1]),vreg(ops[2])
        ln=int(ops[3],0)&0x1F; lanes=int(ops[4],0)&0xF
        return u32(OP_C0|(1<<12)|(vd<<8)|(vs1<<16)|(vs2<<19)|(ln<<22)|(lanes<<27))
    if op=='vlw':
        mm=MEMRE.match(ops[1]); return u32(OP_C1|(0<<12)|(vreg(ops[0])<<8)|(reg(mm.group(2))<<15)|((imm(mm.group(1))&0xFFF)<<20))
    if op=='vsw':
        mm=MEMRE.match(ops[1]); im=imm(mm.group(1))&0xFFF
        return u32(OP_C1|(1<<12)|(vreg(ops[0])<<20)|(reg(mm.group(2))<<15)|((im&0x1F)<<7)|((im>>5)<<25))
    if op=='gflow':
        # gflow src1, src2, dst, count, mode   (path latency derived in HW)
        #   src1=rs1[19:15] src2=rs2[24:20] dst=rd[11:7] count=[31:27] mode=[26]
        s1,s2,dr=reg(ops[0]),reg(ops[1]),reg(ops[2])
        cnt=reg(ops[3]); mode=int(ops[4],0)&1
        return u32(OP_C0|(3<<12)|(dr<<7)|(s1<<15)|(s2<<20)|(mode<<26)|(cnt<<27))
    raise ValueError(f"unknown op '{op}'")

# ---------------------------------------------------------------------------
# GFLOW operand hazard check
#
# GFLOW reads its four scalar operands (src1, src2, dst, count) from the
# register file in ID, with no forwarding and no interlock -- unlike every
# other instruction on the scalar path. A write fewer than GFLOW_HAZARD_DIST
# instructions earlier is therefore read STALE, which silently yields a wrong
# base address or block count (a zero count hangs the GFLOW FSM outright).
# Measured on the RTL: distance 1 and 2 fail, 3 and beyond are correct.
#
# Limitation: this is a straight-line scan. It does not follow branches, so a
# GFLOW reached by a back-edge whose operands are written late in the loop is
# not caught; a warning is emitted if a label sits inside the window.
# ---------------------------------------------------------------------------
GFLOW_HAZARD_DIST = 3

def dest_reg(op, ops):
    """Scalar register written by this instruction, or None."""
    try:
        if op in RTYPE or op in ITYPE or op in SHIFT or op in LOAD:
            return reg(ops[0])
        if op in ('lui', 'auipc', 'mv', 'li', 'jalr'):
            return reg(ops[0])
        if op == 'jal':
            return 1 if len(ops) == 1 else reg(ops[0])
    except Exception:
        return None
    return None

def check_gflow_hazards(prog, labels):
    """Return (errors, warnings) for GFLOW operands written too recently."""
    parsed = []
    for pc, line in prog:
        m = re.match(r'(\S+)\s*(.*)', line)
        parsed.append((m.group(1).lower(), split_ops(m.group(2)), pc, line))
    label_pcs = set(labels.values())
    errs, warns = [], []
    for j, (op, ops, pc, line) in enumerate(parsed):
        if op != 'gflow' or len(ops) < 4:
            continue
        try:
            srcs = {reg(ops[k]) for k in range(4)}
        except Exception:
            continue
        for back in range(1, GFLOW_HAZARD_DIST):
            i = j - back
            if i < 0:
                break
            wop, wops, wpc, wline = parsed[i]
            d = dest_reg(wop, wops)
            if d is not None and d != 0 and d in srcs:
                errs.append(f"  pc 0x{pc:04x}: '{line}'\n"
                            f"    reads x{d}, written {back} instruction(s) earlier "
                            f"by '{wline}' (pc 0x{wpc:04x})")
            if wpc in label_pcs:
                warns.append(f"  pc 0x{pc:04x}: a branch target sits {back} "
                             f"instruction(s) before this gflow; the operand "
                             f"distance may be shorter on some paths")
    return errs, warns

def main():
    args=sys.argv[1:]; inp=None; out=None
    i=0
    while i<len(args):
        if args[i]=='--no-hazard-check': assemble.skip_hazard_check=True; i+=1
        elif args[i]=='-o': out=args[i+1]; i+=2
        else: inp=args[i]; i+=1
    with open(inp) as f: lines=f.readlines()
    try:
        words=assemble(lines)
    except ValueError as e:
        sys.stderr.write(f"asm.py: {inp}: {e}\n")
        sys.exit(1)
    txt='\n'.join(f"{w:08x}" for w in words)+'\n'
    if out:
        with open(out,'w') as f: f.write(txt)
    else:
        sys.stdout.write(txt)

if __name__=='__main__':
    main()

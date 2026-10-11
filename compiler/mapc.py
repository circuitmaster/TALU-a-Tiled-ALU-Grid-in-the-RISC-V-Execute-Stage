#!/usr/bin/env python3
"""mapc.py -- TALU grid mapper.

Takes the kernel descriptors produced by the LLVM pass (TALUMap.so) and turns
each one into a TALU grid configuration + streaming program:

    kernel JSON (expression DAG)  ->  per-tile config  ->  .s (GCFG/GCFGI/GFLOW)

Mapping rules (the fabric constraints are summarised in the top-level README):
  * every internal DAG node is scheduled to column = depth(node) - 1, so a
    dependent chain becomes a column pipeline (one tile = one cycle);
  * a child that is an inner node feeds the tile from the West neighbour;
    a constant leaf becomes the tile's constant register (GCFGI, source C);
    a stream leaf is a column-0 West injection, or the delayed stream-B tap
    (source E) when the consuming tile sits in a later column;
  * reductions materialize the anti-diagonal W+SW collapse to tile (0,N-1)
    in the columns after the compute, and run GFLOW in accumulate mode;
  * element-wise results are routed to a drainable perimeter tile with COPYA.

Usage:  mapc.py kernels.talu.json [--avl 1024] [--kernel name] [-o out.s]
        mapc.py ... --list          # just report what is mappable
"""
import argparse, json, sys

N = 4                      # grid dimension (talu_pkg::GRID_N)
OPS = {"add", "sub", "mul", "and", "or", "xor", "shl", "min", "max"}


class Unsupported(Exception):
    """Raised when a kernel does not fit the fabric; taluc reports and skips."""


# ---------------------------------------------------------------- DAG helpers
def depth(e):
    return 0 if "op" not in e else 1 + max(depth(e["a"]), depth(e["b"]))


def loads_in_order(e, out):
    """Stream arguments in operand order (a before b) = injection order."""
    if "load" in e:
        if e["load"] not in out:
            out.append(e["load"])
    elif "op" in e:
        loads_in_order(e["a"], out)
        loads_in_order(e["b"], out)
    return out


def walk_nodes(e, out):
    """(node, column) for every internal node; column = depth-1."""
    if "op" in e:
        out.append((e, depth(e) - 1))
        walk_nodes(e["a"], out)
        walk_nodes(e["b"], out)
    return out


# ------------------------------------------------------------------- mapping
class Mapping:
    def __init__(self, name, pattern):
        self.name, self.pattern = name, pattern
        self.cfg = []        # (row, col, op, srcA, srcB, drain)
        self.consts = {}     # (row, col) -> value
        self.mode = 0        # GFLOW mode: 0 = stream, 1 = accumulate
        self.streamA = self.streamB = 0
        self.dst_arg = None

    def set(self, r, c, op, sa, sb, drain=0):
        self.cfg = [t for t in self.cfg if (t[0], t[1]) != (r, c)]
        self.cfg.append((r, c, op, sa, sb, drain))


def src_for(child, col, mapping, row):
    """Operand source letter for a child node consumed by a tile at `col`."""
    if "op" in child:
        if depth(child) - 1 != col - 1:
            raise Unsupported("non-adjacent inner operand (needs COPYA padding "
                              "the mapper does not insert yet)")
        return "W"
    if "const" in child:
        mapping.consts[(row, col)] = child["const"]
        return "C"
    # stream leaf
    if col == 0:
        return "W"                      # column-0 West injection (A or B feed)
    if child["load"] != mapping.streamB:
        raise Unsupported("a later column can only tap stream B (source E)")
    return "E"


def map_kernel(k):
    expr, pattern = k["expr"], k["pattern"]
    m = Mapping(k["name"], pattern)

    streams = loads_in_order(expr, [])
    if not streams:
        raise Unsupported("kernel reads no array")
    if len(streams) > 2:
        raise Unsupported(f"{len(streams)} input streams; GFLOW provides 2 "
                          "(multi-pass lowering is future work)")
    m.streamA = streams[0]
    m.streamB = streams[1] if len(streams) > 1 else streams[0]
    m.dst_arg = k.get("dst_arg")

    nodes = walk_nodes(expr, [])
    maxcol = (depth(expr) - 1) if nodes else -1
    if maxcol >= N:
        raise Unsupported(f"expression depth {maxcol + 1} exceeds {N} columns")

    # every lane (row) runs the same compute DAG
    ecols = set()
    for e, c in nodes:
        for r in range(N):
            sa = src_for(e["a"], c, m, r)
            sb = src_for(e["b"], c, m, r)
            if "E" in (sa, sb):
                ecols.add(c)
            m.set(r, c, e["op"], sa, sb)
    # the hardware derives one EXTB column from the configuration
    if len(ecols) > 1:
        raise Unsupported("stream B tapped in more than one column")

    if pattern == "map":
        if m.dst_arg is None:
            raise Unsupported("map kernel without an array destination")
        if maxcol < 0:                                  # pure copy
            for r in range(N):
                m.set(r, 0, "copya", "W", "W")
            maxcol = 0
        if maxcol == 0:
            drain_col = 0                               # column 0 is drainable
        else:
            for c in range(maxcol + 1, N):              # route to the perimeter
                for r in range(N):
                    m.set(r, c, "copya", "W", "W")
            drain_col = N - 1
        # drain the last column, whether it is compute or routing
        for (r, c, op, sa, sb, _) in list(m.cfg):
            if c == drain_col:
                m.set(r, c, op, sa, sb, 1)
        m.mode = 0
    else:                                               # reduction
        if maxcol > 0:
            raise Unsupported(f"reduction of a depth-{maxcol + 1} expression "
                              f"needs {maxcol + N} columns, have {N}")
        if maxcol < 0:                                  # s += a[i]
            for r in range(N):
                m.set(r, 0, "copya", "W", "W")
        # anti-diagonal collapse: level k adds rows (N-1-k) and (N-k)
        for k in range(1, N):
            m.set(N - 1 - k, k, "add", "W", "SW", 1 if k == N - 1 else 0)
            for r in range(0, N - 1 - k):
                m.set(r, k, "copya", "W", "W")
        m.mode = 1
    return m


# ------------------------------------------------------------------ emission
def li(reg, val):
    """Load a 32-bit constant into a scalar register (addi / lui / lui+addi)."""
    if -2048 <= val < 2048:
        return [f"addi {reg}, x0, {val}"]
    hi, lo = (val + 0x800) >> 12, ((val & 0xFFF) ^ 0x800) - 0x800
    out = [f"lui {reg}, {hi}"]
    if lo:
        out.append(f"addi {reg}, {reg}, {lo}")
    return out


def region_bytes(avl):
    return ((avl * 4 + 4095) // 4096) * 4096


def emit(m, avl, nptr):
    """Grid configuration + scalar setup + GFLOW, as TALU assembly."""
    if avl % N:
        raise Unsupported(f"AVL {avl} is not a multiple of N={N}")
    reg = region_bytes(avl)
    base = lambda arg: arg * reg
    dst = base(m.dst_arg) if m.pattern == "map" else nptr * reg

    L = [f"# auto-generated by mapc.py from the LLVM kernel descriptor",
         f"#   kernel={m.name} pattern={m.pattern} AVL={avl} N={N}",
         f"#   streamA=arg{m.streamA} streamB=arg{m.streamB} dst=0x{dst:x}"]
    # scalar setup first: GFLOW reads its operands in ID without forwarding,
    # and the GCFG block below provides the required spacing.
    L += li("x5", base(m.streamA))
    L += li("x6", base(m.streamB))
    L += li("x7", dst)
    L += li("x8", avl // N)

    byval = {}                                   # one load per distinct value
    for (r, c), v in sorted(m.consts.items()):
        byval.setdefault(v, []).append((r, c))
    for v, tiles in sorted(byval.items()):
        L += li("x9", v)
        L += [f"gcfgi {r},{c}, x9" for (r, c) in tiles]
    for (r, c, op, sa, sb, dr) in sorted(m.cfg, key=lambda t: (t[1], t[0])):
        L.append(f"gcfg {r},{c}, {op}, {sa},{sb}, {dr}")
    L.append(f"gflow x5, x6, x7, x8, {m.mode}")
    L.append("ecall")
    return "\n".join(L) + "\n"


# ----------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("json")
    ap.add_argument("--avl", type=int, default=1024)
    ap.add_argument("--kernel")
    ap.add_argument("-o", "--out")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()

    ks = json.load(open(a.json))["kernels"]
    if a.kernel:
        ks = [k for k in ks if k["name"] == a.kernel]
        if not ks:
            sys.exit(f"mapc: no kernel named {a.kernel}")

    outs, failed = [], 0
    for k in ks:
        try:
            m = map_kernel(k)
            s = emit(m, a.avl, k["nargs_ptr"])
            used = len({(r, c) for (r, c, *_) in m.cfg})
            if a.list:
                print(f"  {k['name']:<12} {k['pattern']:<6} "
                      f"{used:2d}/{N*N} tiles  mode={m.mode}")
            else:
                outs.append(s)
        except Unsupported as e:
            failed += 1
            print(f"  {k['name']:<12} UNSUPPORTED: {e}", file=sys.stderr)

    if not a.list and outs:
        txt = "\n".join(outs)
        if a.out:
            open(a.out, "w").write(txt)
        else:
            sys.stdout.write(txt)
    return 1 if (failed and a.kernel) else 0


if __name__ == "__main__":
    sys.exit(main())

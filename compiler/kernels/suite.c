// Kernels for the TALU auto-mapping compiler.
//
// Each loop is plain C; the only TALU-specific thing is the `talu` annotation
// that tells the LLVM pass "try to map this function onto the grid". The pass
// extracts the loop-body expression DAG, mapc.py schedules it onto tiles.
//
// The host semantics of these functions are also the reference used by
// verify.py: the same C is compiled natively and its output compared against
// the TALU simulation of the generated configuration.
#define TALU __attribute__((annotate("talu")))

// --- element-wise maps ------------------------------------------------------
TALU void vvadd(const int *a, const int *b, int *d, int n) {
  for (int i = 0; i < n; i++) d[i] = a[i] + b[i];
}

TALU void vmul(const int *a, const int *b, int *d, int n) {
  for (int i = 0; i < n; i++) d[i] = a[i] * b[i];
}

TALU void vsub(const int *a, const int *b, int *d, int n) {
  for (int i = 0; i < n; i++) d[i] = a[i] - b[i];
}

TALU void vmin(const int *a, const int *b, int *d, int n) {
  for (int i = 0; i < n; i++) d[i] = a[i] < b[i] ? a[i] : b[i];
}

TALU void vmax(const int *a, const int *b, int *d, int n) {
  for (int i = 0; i < n; i++) d[i] = a[i] > b[i] ? a[i] : b[i];
}

// --- constant operand (per-tile constant register, source C) ----------------
TALU void scale(const int *a, int *d, int n) {
  for (int i = 0; i < n; i++) d[i] = a[i] * 5;
}

// --- fused MAC: constant multiply + delayed stream-B tap (source E) ---------
TALU void saxpy(const int *x, const int *y, int *d, int n) {
  for (int i = 0; i < n; i++) d[i] = 3 * x[i] + y[i];
}

// --- deep dependent chain: fused across columns -----------------------------
TALU void power8(const int *a, const int *b, int *d, int n) {
  for (int i = 0; i < n; i++) {
    int s = a[i] + b[i];
    s = s * s;          // s^2
    s = s * s;          // s^4
    s = s * s;          // s^8
    d[i] = s;
  }
}

// --- reductions (spatial diagonal collapse + accumulate) --------------------
TALU int dot(const int *a, const int *b, int n) {
  int s = 0;
  for (int i = 0; i < n; i++) s += a[i] * b[i];
  return s;
}

TALU int vsum(const int *a, int n) {
  int s = 0;
  for (int i = 0; i < n; i++) s += a[i];
  return s;
}

TALU int sumsq(const int *a, int n) {
  int s = 0;
  for (int i = 0; i < n; i++) s += a[i] * a[i];
  return s;
}

// --- expected to be REJECTED: three input streams need multi-pass lowering --
TALU void median3(const int *a, const int *b, const int *c, int *d, int n) {
  for (int i = 0; i < n; i++) {
    int lo = a[i] < b[i] ? a[i] : b[i];
    int hi = a[i] > b[i] ? a[i] : b[i];
    int m  = hi < c[i] ? hi : c[i];
    d[i] = lo > m ? lo : m;
  }
}

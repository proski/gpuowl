// gpuOwl, an OpenCL Mersenne primality test.
// Copyright (C) 2017 Mihai Preda.

// The data is organized in pairs of words in a matrix WIDTH x HEIGHT.
// The pair (a, b) is sometimes interpreted as the complex value a + i*b.
// The order of words is column-major (i.e. transposed from the usual row-major matrix order).

// Expected defines: EXP the exponent.
// WIDTH, HEIGHT
// NW, NH

#pragma OPENCL FP_CONTRACT ON

#ifdef cl_khr_fp64
#pragma OPENCL EXTENSION cl_khr_fp64 : enable
#endif

// OpenCL 2.x introduces the "generic" memory space, so there's no need to specify "global" on pointers everywhere.
#if __OPENCL_C_VERSION__ >= 200
#define G
#else
#define G global
#endif

// Number of words
#define NWORDS (WIDTH * HEIGHT * 2u)
#define G_W (WIDTH  / NW)
#define G_H (HEIGHT / NH)

// Used in bitlen() and weighting.
#define STEP (NWORDS - (EXP % NWORDS))

uint extra(uint k) { return ((ulong) STEP) * k % NWORDS; }

// Is the word at pos a big word (BASE_BITLEN+1 bits)? (vs. a small, BASE_BITLEN bits word).
bool isBigWord(uint k) { return extra(k) + STEP < NWORDS; }
// { return extra(k) < extra(k + 1); }

// Number of bits for the word at pos.
uint bitlen(uint k) { return EXP / NWORDS + isBigWord(k); }

// Propagate carry this many pairs of words.
#define CARRY_LEN 16

typedef double T;
typedef double2 T2;

typedef int Word;
typedef int2 Word2;
typedef long Carry;

T2 U2(T a, T b) { return (T2)(a, b); }

T add1(T a, T b) { return a + b; }
T sub1(T a, T b) { return a - b; }

T2 add(T2 a, T2 b) { return a + b; }
T2 sub(T2 a, T2 b) { return a - b; }

T shl1(T a, uint k) { return a * (1 << k); }

// complex mul
T2 mul(T2 a, T2 b) { return U2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x); }

// complex square
T2 sq(T2 a) { return U2((a.x + a.y) * (a.x - a.y), 2 * a.x * a.y); }

T mul1(T a, T b) { return a * b; }

T2 mul_t4(T2 a)  { return U2(a.y, -a.x); }                          // mul(a, U2( 0, -1)); }
T2 mul_t8(T2 a)  { return U2(a.y + a.x, a.y - a.x) * M_SQRT1_2; }   // mul(a, U2( 1, -1)) * (T)(M_SQRT1_2); }
T2 mul_3t8(T2 a) { return U2(a.x - a.y, a.x + a.y) * - M_SQRT1_2; } // mul(a, U2(-1, -1)) * (T)(M_SQRT1_2); }

T2 shl(T2 a, uint k) { return U2(shl1(a.x, k), shl1(a.y, k)); }

T2 addsub(T2 a) { return U2(add1(a.x, a.y), sub1(a.x, a.y)); }
T2 swap(T2 a) { return U2(a.y, a.x); }
T2 conjugate(T2 a) { return U2(a.x, -a.y); }

void bar()    { barrier(CLK_LOCAL_MEM_FENCE); }
void bigBar() { barrier(CLK_GLOBAL_MEM_FENCE | CLK_LOCAL_MEM_FENCE); }

Word lowBits(int u, uint bits) { return (u << (32 - bits)) >> (32 - bits); }

Word carryStep(Carry x, Carry *carry, int bits) {
  x += *carry;
  Word w = lowBits(x, bits);
  *carry = (x - w) >> bits;
  return w;
}

// Simpler version of signbit(a).
uint signBit(double a) { return ((uint *)&a)[1] >> 31; }

uint oldBitlen(double a) { return EXP / NWORDS + signBit(a); }

Carry unweight(T x, T weight) { return rint(x * fabs(weight)); }  
// return rint(weighted);
// float err = rounded - weighted;
// *maxErr = max(*maxErr, fabs(err));


Word2 unweightAndCarry(uint mul, T2 u, Carry *carry, T2 weight) {
  Word a = carryStep(mul * unweight(u.x, weight.x), carry, oldBitlen(weight.x));
  Word b = carryStep(mul * unweight(u.y, weight.y), carry, oldBitlen(weight.y));
  return (Word2) (a, b);
}

T2 weightAux(Word x, Word y, T2 weight) { return U2(x, y) * fabs(weight); }

T2 weight(Word2 a, T2 w) { return weightAux(a.x, a.y, w); }

T2 carryAndWeight(Word2 u, Carry *carry, T2 weight) {
  Word x = carryStep(u.x, carry, oldBitlen(weight.x));
  Word y = carryStep(u.y, carry, oldBitlen(weight.y));
  return weightAux(x, y, weight);
}

// No carry out. The final carry is "absorbed" in the last word.
T2 carryAndWeightFinal(Word2 u, Carry carry, T2 w) {
  Word x = carryStep(u.x, &carry, oldBitlen(w.x));
  Word y = u.y + carry;
  return weightAux(x, y, w);
}

// Carry propagation from word and carry.
Word2 carryWord(Word2 a, Carry *carry, uint pos) {
  a.x = carryStep(a.x, carry, bitlen(2 * pos + 0));
  a.y = carryStep(a.y, carry, bitlen(2 * pos + 1));
  return a;
}

T2 foo2(T2 a, T2 b) {
  a = addsub(a);
  b = addsub(b);
  return addsub(U2(mul1(a.x, b.x), mul1(a.y, b.y)));
}

// computes 2*[x^2+y^2 + i*(2*x*y)]. Needs a name.
T2 foo(T2 a) { return foo2(a, a); }

#define X2(a, b) { T2 t = a; a = add(t, b); b = sub(t, b); }
#define SWAP(a, b) { T2 t = a; a = b; b = t; }

void fft4Core(T2 *u) {
  X2(u[0], u[2]);
  X2(u[1], u[3]);
  u[3] = mul_t4(u[3]);
  X2(u[0], u[1]);
  X2(u[2], u[3]);
}

void fft4(T2 *u) {
  fft4Core(u);
  // revbin [0, 2, 1, 3] undo
  SWAP(u[1], u[2]);
}

void fft8(T2 *u) {
  for (int i = 0; i < 4; ++i) { X2(u[i], u[i + 4]); }
  u[5] = mul_t8(u[5]);
  u[6] = mul_t4(u[6]);
  u[7] = mul_3t8(u[7]);
  
  fft4Core(u);
  fft4Core(u + 4);

  // revbin [0, 4, 2, 6, 1, 5, 3, 7] undo
  SWAP(u[1], u[4]);
  SWAP(u[3], u[6]);
}

void shufl(uint WG, local T *lds, T2 *u, uint n, uint f) {
  uint me = get_local_id(0);
  uint m = me / f;
  
  for (int b = 0; b < 2; ++b) {
    if (b) { bar(); }
    for (uint i = 0; i < n; ++i) { lds[(m + i * WG / f) / n * f + m % n * WG + me % f] = ((T *) (u + i))[b]; }
    bar();
    for (uint i = 0; i < n; ++i) { ((T *) (u + i))[b] = lds[i * WG + me]; }
  }
}

void tabMul(uint WG, const G T2 *trig, T2 *u, uint n, uint f) {
  uint me = get_local_id(0);
  for (int i = 1; i < n; ++i) { u[i] = mul(u[i], trig[me / f + i * (WG / f)]); }
}

void fft1K(local T *lds, T2 *u, const G T2 *trig) {
  for (int s = 6; s >= 0; s -= 2) {
    fft4(u);
    if (s != 6) { bar(); }
    shufl(256,   lds, u, 4, 1 << s);
    tabMul(256, trig, u, 4, 1 << s);
  }

  fft4(u);
}

void fft2K(local T *lds, T2 *u, const G T2 *trig) {
  for (int s = 5; s >= 2; s -= 3) {
    fft8(u);
    if (s != 5) { bar(); }
    shufl(256,   lds, u, 8, 1 << s);
    tabMul(256, trig, u, 8, 1 << s);
  }

  fft8(u);

  uint me = get_local_id(0);
  for (int b = 0; b < 2; ++b) {
    bar();
    for (int i = 0; i < 8; ++i) { lds[(me + i * 256) / 4 + me % 4 * 512] = ((T *) (u + i))[b]; }
    bar();
    for (int i = 0; i < 4; ++i) {
      ((T *) (u + i))[b]     = lds[i * 512       + me];
      ((T *) (u + i + 4))[b] = lds[i * 512 + 256 + me];
    }
  }

  for (int i = 1; i < 4; ++i) {
    u[i]     = mul(u[i],     trig[i * 512       + me]);
    u[i + 4] = mul(u[i + 4], trig[i * 512 + 256 + me]);
  }

  fft4(u);
  fft4(u + 4);

  // fix order: interleave u[0:3] and u[4:7], like (u.even, u.odd) = (u.lo, u.hi).
  SWAP(u[1], u[2]);
  SWAP(u[1], u[4]);
  SWAP(u[5], u[6]);
  SWAP(u[3], u[6]);
}

void read(uint WG, uint N, T2 *u, G T2 *in, uint base) {
  for (int i = 0; i < N; ++i) { u[i] = in[base + i * WG + (uint) get_local_id(0)]; }
}

void write(uint WG, uint N, T2 *u, G T2 *out, uint base) {
  for (int i = 0; i < N; ++i) { out[base + i * WG + (uint) get_local_id(0)] = u[i]; }
}

// Carry propagation with optional MUL-3, over CARRY_LEN words.
// Input is conjugated and inverse-weighted.
void carryACore(uint mul, const G T2 *in, const G T2 *A, G Word2 *out, G Carry *carryOut, local uint *lds) {
  uint g  = get_group_id(0);
  uint me = get_local_id(0);
  uint gx = g % NW;
  uint gy = g / NW;

  uint step = G_W * gx + WIDTH * CARRY_LEN * gy;
  in  += step;
  out += step;
  A   += step;

  Carry carry = 0;

  for (int i = 0; i < CARRY_LEN; ++i) {
    uint p = WIDTH * i + me;
    out[p] = unweightAndCarry(mul, conjugate(in[p]), &carry, A[p]);
  }
  carryOut[G_W * g + me] = carry;
}

// Inputs normal (non-conjugate); outputs conjugate.
// bigTrig: see genSquareTrig() in gpuowl.cpp
void csquare(uint WG, uint W, uint H, G T2 *io, const G T2 *bigTrig) {
  uint g  = get_group_id(0);
  uint me = get_local_id(0);

  if (g == 0 && me == 0) {
    io[0]     = shl(foo(conjugate(io[0])), 2);
    io[W / 2] = shl(sq(conjugate(io[W / 2])), 3);
    return;
  }

  uint GPL = W / (WG * 2); // "Groups Per Line", == 4.
  uint line = g / GPL;
  uint posInLine = g % GPL * WG + me;

  T2 t = swap(mul(bigTrig[posInLine], bigTrig[W + line]));
  
  uint k = line * W + posInLine;
  uint v = ((H - line) % H) * W + (W - 1) - posInLine + ((line - 1) >> 31);
  
  T2 a = io[k];
  T2 b = conjugate(io[v]);
  X2(a, b);
  b = mul(b, conjugate(t));
  X2(a, b);

  a = sq(a);
  b = sq(b);

  X2(a, b);
  b = mul(b,  t);
  X2(a, b);
  
  io[k] = conjugate(a);
  io[v] = b;
}

// Like csquare(), but for multiplication.
void cmul(uint WG, uint W, uint H, G T2 *io, const G T2 *in, const G T2 *bigTrig) {
  // const G T2 *bigTrig) {
  uint g  = get_group_id(0);
  uint me = get_local_id(0);

  if (g == 0 && me == 0) {
    io[0]     = shl(foo2(conjugate(io[0]), conjugate(in[0])), 2);
    io[W / 2] = shl(conjugate(mul(io[W / 2], in[W / 2])), 3);
    return;
  }

  uint GPL = W / (WG * 2);
  uint line = g / GPL;
  uint posInLine = g % GPL * WG + me;

  T2 t = swap(mul(bigTrig[posInLine], bigTrig[W + line]));
  
  uint k = line * W + posInLine;
  uint v = ((H - line) % H) * W + (W - 1) - posInLine + ((line - 1) >> 31);
  
  T2 a = io[k];
  T2 b = conjugate(io[v]);
  X2(a, b);
  b = mul(b, conjugate(t));
  X2(a, b);
  
  T2 c = in[k];
  T2 d = conjugate(in[v]);
  X2(c, d);
  d = mul(d, conjugate(t));
  X2(c, d);

  a = mul(a, c);
  b = mul(b, d);

  X2(a, b);
  b = mul(b,  t);
  X2(a, b);
  
  io[k] = conjugate(a);
  io[v] = b;
}

// transpose LDS 64 x 64.
void transposeLDS(local T *lds, T2 *u) {
  uint me = get_local_id(0);
  for (int b = 0; b < 2; ++b) {
    if (b) { bar(); }
    for (int i = 0; i < 16; ++i) {
      uint l = i * 4 + me / 64;
      // uint c = me % 64;
      lds[l * 64 + (me + l) % 64 ] = ((T *)(u + i))[b];
    }
    bar();
    for (int i = 0; i < 16; ++i) {
      uint c = i * 4 + me / 64;
      uint l = me % 64;
      ((T *)(u + i))[b] = lds[l * 64 + (c + l) % 64];
    }
  }
}

void transpose(uint W, uint H, local T *lds, const G T2 *in, G T2 *out, const G T2 *trig) {
  uint GPW = (W - 1) / 64 + 1, GPH = (H - 1) / 64 + 1;
  uint PW = GPW * 64, PH = GPH * 64; // padded to multiple of 64.
  
  uint g = get_group_id(0);
  // uint gx = g % GPW, gy = g / GPW;
  uint gy = g % GPH, gx = g / GPH;
  gx = (gy + gx) % GPW;

  in   += gy * 64 * W + gx * 64;
  out  += gy * 64     + gx * 64 * H;
  
  uint me = get_local_id(0), mx = me % 64, my = me / 64;
  T2 u[16];

  for (int i = 0; i < 16; ++i) { u[i] = in[(4 * i + my) * W + mx]; }

  transposeLDS(lds, u);

  for (int i = 0; i < 16; ++i) {
    uint k = mul24(64 * gy + mx, 64 * gx + my + (uint) i * 4);
    u[i] = mul(u[i], mul(trig[k / (W * H / 2048)], trig[2048 + k % (W * H / 2048)]));
    out[(4 * i + my) * H + mx] = u[i];
  }
}

#ifndef ALT_RESTRICT

#define P(x) global x * restrict
#define CP(x) const P(x)
typedef CP(T2) Trig;

#else

#define P(x) global x *
#define CP(x) const P(x)
typedef CP(T2) restrict Trig;

#endif

#define KERNEL(x) kernel __attribute__((reqd_work_group_size(x, 1, 1))) void

KERNEL(G_W) fftW(P(T2) io, Trig smallTrig) {
  local T lds[WIDTH];
  T2 u[NW];

  uint g = get_group_id(0);
  io += WIDTH * g;

  read(G_W, NW, u, io, 0);
  fft2K(lds, u, smallTrig);
  write(G_W, NW, u, io, 0);
}

KERNEL(G_H) fftH(P(T2) io, Trig smallTrig) {
  local T lds[HEIGHT];
  T2 u[NH];

  uint g = get_group_id(0);
  io += HEIGHT * g;

  read(G_H, NH, u, io, 0);
  fft2K(lds, u, smallTrig);
  write(G_H, NH, u, io, 0);
}

// fftPremul: weight words with "A" (for IBDWT) followed by FFT.
KERNEL(G_W) fftP(CP(Word2) in, P(T2) out, CP(T2) A, Trig smallTrig) {
  local T lds[WIDTH];
  T2 u[NW];

  uint g = get_group_id(0);
  uint step = WIDTH * g;
  A   += step;
  in  += step;
  out += step;

  uint me = get_local_id(0);

  for (int i = 0; i < NW; ++i) {
    uint p = G_W * i + me;
    u[i] = weight(in[p], A[p]);
  }

  fft2K(lds, u, smallTrig);
  write(G_W, NW, u, out, 0);
}

KERNEL(G_W) carryA(CP(T2) in, CP(T2) A, P(Word2) out, P(Carry) carryOut) {
  local uint lds[1];
  carryACore(1, in, A, out, carryOut, lds);
}

KERNEL(G_W) carryM(CP(T2) in, CP(T2) A, P(Word2) out, P(Carry) carryOut) {
  local uint lds[1];
  carryACore(3, in, A, out, carryOut, lds);
}

KERNEL(G_W) carryB(P(Word2) io, CP(Carry) carryIn) {
  uint g  = get_group_id(0);
  uint me = get_local_id(0);
  
  uint gx = g % NW;
  uint gy = g / NW;
  
  uint step = G_W * gx + WIDTH * CARRY_LEN * gy;
  io += step;

  uint HB = HEIGHT / CARRY_LEN;

  // TODO: try & vs. %.
  uint prev = (gy + HB * G_W * gx + HB * me + (HB * WIDTH - 1)) % (HB * WIDTH);
  uint prevLine = prev % HB;
  uint prevCol  = prev / HB;
  Carry carry = carryIn[WIDTH * prevLine + prevCol];
  
  for (int i = 0; i < CARRY_LEN; ++i) {
    uint pos = CARRY_LEN * gy + HEIGHT * G_W * gx + HEIGHT * me + i;
    uint p = i * WIDTH + me;
    io[p] = carryWord(io[p], &carry, pos);
    if (!carry) { return; }
  }
}

// The "carryFused" is equivalent to the sequence: fftW, carryA, carryB, fftPremul.
// It uses "stairway" carry data forwarding from one group to the next.
KERNEL(G_W) carryFused(P(T2) io, P(Carry) carryShuttle, volatile P(uint) ready,
                       CP(T2) A, CP(T2) iA, Trig smallTrig) {
  local T lds[WIDTH];

  uint gr = get_group_id(0);
  uint me = get_local_id(0);
  
  uint H = HEIGHT;
  uint line = gr % H;
  uint step = WIDTH * line;
  io += step;
  A  += step;
  iA += step;
  
  T2 u[NW];
  Word2 wu[NW];
  
  read(G_W, NW, u, io, 0);
  fft2K(lds, u, smallTrig);
  
  for (int i = 0; i < NW; ++i) {
    uint p = i * G_W + me;
    Carry carry = 0;
    wu[i] = unweightAndCarry(1, conjugate(u[i]), &carry, iA[p]);
    if (gr < H) { carryShuttle[gr * WIDTH + p] = carry; }
  }

  bigBar();

  // Signal that this group is done writing the carry.
  if (gr < H && me == 0) { atomic_xchg(&ready[gr], 1); }

  if (gr == 0) { return; }
    
  // Wait until the previous group is ready with the carry.
  if (me == 0) { while(!atomic_xchg(&ready[gr - 1], 0)); }

  bigBar();

  for (int i = 0; i < NW; ++i) {
    uint p = i * G_W + me;
    Carry carry = carryShuttle[(gr - 1) * WIDTH + ((p + WIDTH - gr / H) % WIDTH)];
    u[i] = carryAndWeightFinal(wu[i], carry, A[p]);
  }

  fft2K(lds, u, smallTrig);
  write(G_W, NW, u, io, 0);
}

KERNEL(256) transposeW(CP(T2) in, P(T2) out, Trig trig) {
  local T lds[4096];
  transpose(WIDTH, HEIGHT, lds, in, out, trig);
}

KERNEL(256) transposeH(CP(T2) in, P(T2) out, Trig trig) {
  local T lds[4096];
  transpose(HEIGHT, WIDTH, lds, in, out, trig);
}

KERNEL(G_H) square(P(T2) io, Trig bigTrig)  { csquare(G_H, HEIGHT, WIDTH, io, bigTrig); }

KERNEL(G_H) multiply(P(T2) io, CP(T2) in, Trig bigTrig)  { cmul(G_H, HEIGHT, WIDTH, io, in, bigTrig); }

void reverse(uint WG, local T2 *lds, T2 *u, bool bump) {
  uint me = get_local_id(0);
  uint rm = WG - 1 - me + bump;
  
  bar();

  lds[rm + 0 * WG] = u[7];
  lds[rm + 1 * WG] = u[6];
  lds[rm + 2 * WG] = u[5];  
  lds[bump ? ((rm + 3 * WG) % (4 * WG)) : (rm + 3 * WG)] = u[4];
  
  bar();
  for (int i = 0; i < 4; ++i) { u[4 + i] = lds[i * WG + me]; }
}

void halfSq(uint WG, uint N, T2 *u, T2 *v, T2 tt, const G T2 *bigTrig, bool special) {
  uint g = get_group_id(0);
  uint me = get_local_id(0);
  for (int i = 0; i < N / 2; ++i) {
    T2 a = u[i];
    T2 b = conjugate(v[N / 2 + i]);
    T2 t = swap(mul(tt, bigTrig[WG * i + me]));
    if (special && i == 0 && g == 0 && me == 0) {
      a = shl(foo(a), 2);
      b = shl(sq(b), 3);
    } else {
      X2(a, b);
      b = mul(b, conjugate(t));
      X2(a, b);
      a = sq(a);
      b = sq(b);
      X2(a, b);
      b = mul(b, t);
      X2(a, b);
    }
    u[i] = conjugate(a);
    v[N / 2 + i] = b;
  }
}

// "fused tail" is equivalent to the sequence: fftH, square, fftH.
// assert(H % 2 == 0);
KERNEL(G_H) tailFused(P(T2) io, Trig smallTrig, P(T2) bigTrig) {
  local T lds[HEIGHT];
  T2 u[NH];
  T2 v[NH];

  uint H = WIDTH;
  uint W = HEIGHT;
  uint g = get_group_id(0);
  uint me = get_local_id(0);
  
  read(G_H, NH, u, io, g * W);
  fft2K(lds, u, smallTrig);
  reverse(G_H, (local T2 *) lds, u, g == 0);

  uint line2 = g ? H - g : (H / 2);
  read(G_H, NH, v, io, line2 * W);
  bar();
  fft2K(lds, v, smallTrig);
  reverse(G_H, (local T2 *) lds, v, false);

  if (g == 0) { for (int i = NH / 2; i < NH; ++i) { SWAP(u[i], v[i]); } }
  
  halfSq(G_H, NH, u, v, bigTrig[W + g],     bigTrig, true);
  halfSq(G_H, NH, v, u, bigTrig[W + line2], bigTrig, false);

  if (g == 0) { for (int i = NH / 2; i < NH; ++i) { SWAP(u[i], v[i]); } }

  reverse(G_H, (local T2 *) lds, v, false);
  reverse(G_H, (local T2 *) lds, u, g == 0);

  bar();
  fft2K(lds, v, smallTrig);
  write(G_H, NH, v, io, line2 * W);

  bar();
  fft2K(lds, u, smallTrig);
  write(G_H, NH, u, io, g * W);
}

#!/usr/bin/env python3
"""Simulate the AVX-512 16x16 block transpose and verify it against reference."""


def lane(idx):
    return idx // 4


def unpacklo_ps(a, b):
    out = [0.0] * 16
    for k in range(4):
        out[4*k + 0] = a[4*k + 0]
        out[4*k + 1] = b[4*k + 0]
        out[4*k + 2] = a[4*k + 1]
        out[4*k + 3] = b[4*k + 1]
    return out


def unpackhi_ps(a, b):
    out = [0.0] * 16
    for k in range(4):
        out[4*k + 0] = a[4*k + 2]
        out[4*k + 1] = b[4*k + 2]
        out[4*k + 2] = a[4*k + 3]
        out[4*k + 3] = b[4*k + 3]
    return out


def unpacklo_pd(a, b):
    out = [0.0] * 16
    for k in range(4):
        out[4*k + 0] = a[4*k + 0]
        out[4*k + 1] = a[4*k + 1]
        out[4*k + 2] = b[4*k + 0]
        out[4*k + 3] = b[4*k + 1]
    return out


def unpackhi_pd(a, b):
    out = [0.0] * 16
    for k in range(4):
        out[4*k + 0] = a[4*k + 2]
        out[4*k + 1] = a[4*k + 3]
        out[4*k + 2] = b[4*k + 2]
        out[4*k + 3] = b[4*k + 3]
    return out


def permutex2var_ps(a, idx, b):
    out = [0.0] * 16
    for i, x in enumerate(idx):
        if x >= 16:
            out[i] = b[x - 16]
        else:
            out[i] = a[x]
    return out


def transpose16x16_sim(src, src_stride):
    # src is a 2D list / matrix; src_stride is inDim
    r = [src[i * src_stride: i * src_stride + 16] for i in range(16)]

    s = [None] * 16
    for i in range(0, 16, 2):
        s[i] = unpacklo_ps(r[i], r[i+1])
        s[i+1] = unpackhi_ps(r[i], r[i+1])

    t = [None] * 16
    for i in range(0, 16, 4):
        t[i] = unpacklo_pd(s[i], s[i+2])
        t[i+1] = unpackhi_pd(s[i], s[i+2])
        t[i+2] = unpacklo_pd(s[i+1], s[i+3])
        t[i+3] = unpackhi_pd(s[i+1], s[i+3])

    idx1 = [0, 1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19, 20, 21, 22, 23]
    out = [None] * 16

    for lane in range(4):
        # Upper half is unused by idx1, but permutex2var indices must stay in [0,31].
        idx0 = [
            lane*4+0, lane*4+1, lane*4+2, lane*4+3,
            lane*4+0+16, lane*4+1+16, lane*4+2+16, lane*4+3+16,
            lane*4+0, lane*4+1, lane*4+2, lane*4+3,
            lane*4+0+16, lane*4+1+16, lane*4+2+16, lane*4+3+16,
        ]
        ab = permutex2var_ps(t[0], idx0, t[4])
        cd = permutex2var_ps(t[8], idx0, t[12])
        out[4*lane] = permutex2var_ps(ab, idx1, cd)

        ab = permutex2var_ps(t[1], idx0, t[5])
        cd = permutex2var_ps(t[9], idx0, t[13])
        out[4*lane+1] = permutex2var_ps(ab, idx1, cd)

        ab = permutex2var_ps(t[2], idx0, t[6])
        cd = permutex2var_ps(t[10], idx0, t[14])
        out[4*lane+2] = permutex2var_ps(ab, idx1, cd)

        ab = permutex2var_ps(t[3], idx0, t[7])
        cd = permutex2var_ps(t[11], idx0, t[15])
        out[4*lane+3] = permutex2var_ps(ab, idx1, cd)

    return out


def reference_transpose(W, out_dim, in_dim):
    WT = [[0.0] * out_dim for _ in range(in_dim)]
    for i in range(out_dim):
        for j in range(in_dim):
            WT[j][i] = W[i][j]
    return WT


def main():
    out_dim, in_dim = 16, 16
    W = [[float(i * 1000 + j) for j in range(in_dim)] for i in range(out_dim)]

    # Flatten W row-major
    W_flat = [W[i][j] for i in range(out_dim) for j in range(in_dim)]
    out = transpose16x16_sim(W_flat, in_dim)

    WT_ref = reference_transpose(W, out_dim, in_dim)

    ok = True
    for j in range(16):
        expected = [W[i][j] for i in range(16)]
        actual = out[j]
        if expected != actual:
            print(f"Mismatch at output row {j}")
            print(f"  expected: {expected}")
            print(f"  actual:   {actual}")
            ok = False

        # Also check against reference placement
        for i in range(16):
            if WT_ref[j][i] != actual[i]:
                print(f"Placement mismatch at ({i},{j})")
                ok = False

    if ok:
        print("16x16 AVX-512 block transpose simulation: PASSED")
    else:
        print("16x16 AVX-512 block transpose simulation: FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())

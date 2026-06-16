#include "transposeWtoWT.h"
#include <immintrin.h>

#if defined(__GNUC__) || defined(__clang__)
#define AVX512_TARGET __attribute__((target("avx512f")))
#else
#define AVX512_TARGET
#endif

// 16x16 float block transpose using AVX-512.
// src : pointer to top-left of 16x16 block in source matrix (row-major, stride srcStride)
// dst : pointer to top-left of 16x16 block in destination matrix (row-major, stride dstStride)
static inline AVX512_TARGET void transpose16x16(const float* src, float* dst, size_t srcStride, size_t dstStride)
{
    __m512 r[16];
    for (int i = 0; i < 16; ++i) {
        r[i] = _mm512_loadu_ps(src + i * srcStride);
    }

    // Stage 1: interleave pairs of rows within each 32-bit lane
    __m512 s[16];
    for (int i = 0; i < 16; i += 2) {
        s[i]     = _mm512_unpacklo_ps(r[i], r[i + 1]);
        s[i + 1] = _mm512_unpackhi_ps(r[i], r[i + 1]);
    }

    // Stage 2: interleave 64-bit pairs -> transposed 4x4 blocks inside each 128-bit lane
    __m512 t[16];
    for (int i = 0; i < 16; i += 4) {
        t[i]     = _mm512_unpacklo_pd(s[i],     s[i + 2]);
        t[i + 1] = _mm512_unpackhi_pd(s[i],     s[i + 2]);
        t[i + 2] = _mm512_unpacklo_pd(s[i + 1], s[i + 3]);
        t[i + 3] = _mm512_unpackhi_pd(s[i + 1], s[i + 3]);
    }

    // Stage 3: gather 128-bit lanes from row groups to form output rows
    const __m512i idx1 = _mm512_setr_epi32(0, 1, 2, 3, 4, 5, 6, 7,
                                            16, 17, 18, 19, 20, 21, 22, 23);
    __m512 out[16];

    for (int lane = 0; lane < 4; ++lane) {
        // Upper half is unused by idx1, but permutex2var indices must stay in [0,31].
        __m512i idx0 = _mm512_setr_epi32(
            lane * 4 + 0, lane * 4 + 1, lane * 4 + 2, lane * 4 + 3,
            lane * 4 + 0 + 16, lane * 4 + 1 + 16, lane * 4 + 2 + 16, lane * 4 + 3 + 16,
            lane * 4 + 0, lane * 4 + 1, lane * 4 + 2, lane * 4 + 3,
            lane * 4 + 0 + 16, lane * 4 + 1 + 16, lane * 4 + 2 + 16, lane * 4 + 3 + 16);

        __m512 ab = _mm512_permutex2var_ps(t[0], idx0, t[4]);
        __m512 cd = _mm512_permutex2var_ps(t[8], idx0, t[12]);
        out[4 * lane] = _mm512_permutex2var_ps(ab, idx1, cd);

        ab = _mm512_permutex2var_ps(t[1], idx0, t[5]);
        cd = _mm512_permutex2var_ps(t[9], idx0, t[13]);
        out[4 * lane + 1] = _mm512_permutex2var_ps(ab, idx1, cd);

        ab = _mm512_permutex2var_ps(t[2], idx0, t[6]);
        cd = _mm512_permutex2var_ps(t[10], idx0, t[14]);
        out[4 * lane + 2] = _mm512_permutex2var_ps(ab, idx1, cd);

        ab = _mm512_permutex2var_ps(t[3], idx0, t[7]);
        cd = _mm512_permutex2var_ps(t[11], idx0, t[15]);
        out[4 * lane + 3] = _mm512_permutex2var_ps(ab, idx1, cd);
    }

    for (int i = 0; i < 16; ++i) {
        _mm512_storeu_ps(dst + i * dstStride, out[i]);
    }
}

// Transpose W[outDim x inDim] -> WT[inDim x outDim]
// W(i, j)  = W[i * inDim + j]
// WT(j, i) = WT[j * outDim + i]
AVX512_TARGET
void transposeWtoWT(const float* W, float* WT, size_t outDim, size_t inDim)
{
    size_t i = 0;
    for (; i + 16 <= outDim; i += 16) {
        size_t j = 0;
        for (; j + 16 <= inDim; j += 16) {
            transpose16x16(W + i * inDim + j, WT + j * outDim + i, inDim, outDim);
        }
        // Tail columns for current 16-row block
        for (size_t ii = i; ii < i + 16; ++ii) {
            for (size_t jj = j; jj < inDim; ++jj) {
                WT[jj * outDim + ii] = W[ii * inDim + jj];
            }
        }
    }
    // Tail rows
    for (size_t ii = i; ii < outDim; ++ii) {
        for (size_t jj = 0; jj < inDim; ++jj) {
            WT[jj * outDim + ii] = W[ii * inDim + jj];
        }
    }
}

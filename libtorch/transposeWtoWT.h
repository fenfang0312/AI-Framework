#pragma once

#include <cstddef>

// Transpose W[outDim x inDim] -> WT[inDim x outDim]
// Layout:
//   W(i, j)  = W[i * inDim + j]
//   WT(j, i) = WT[j * outDim + i]
//
// Implementation uses AVX-512; compile the corresponding .cpp with AVX-512 enabled:
//   g++/clang++ : -mavx512f
//   MSVC        : /arch:AVX512
void transposeWtoWT(const float* W, float* WT, size_t outDim, size_t inDim);

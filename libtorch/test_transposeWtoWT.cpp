#include "transposeWtoWT.h"
#include <cstdio>
#include <vector>

static bool test_transpose(size_t outDim, size_t inDim)
{
    std::vector<float> W(outDim * inDim);
    std::vector<float> WT(inDim * outDim, 0.0f);

    for (size_t i = 0; i < outDim; ++i) {
        for (size_t j = 0; j < inDim; ++j) {
            W[i * inDim + j] = static_cast<float>(i * 1000 + j);
        }
    }

    transposeWtoWT(W.data(), WT.data(), outDim, inDim);

    for (size_t i = 0; i < outDim; ++i) {
        for (size_t j = 0; j < inDim; ++j) {
            float expected = W[i * inDim + j];
            float actual   = WT[j * outDim + i];
            if (actual != expected) {
                std::printf("FAIL at (%zu,%zu): expected %.1f, got %.1f  (outDim=%zu, inDim=%zu)\n",
                            i, j, expected, actual, outDim, inDim);
                return false;
            }
        }
    }
    return true;
}

int main()
{
    const struct { size_t outDim, inDim; } cases[] = {
        {16, 16}, {17, 17}, {31, 33}, {32, 48}, {48, 32},
        {64, 64}, {100, 127}, {127, 100}, {1, 1}, {5, 23}
    };

    bool all_ok = true;
    for (const auto& c : cases) {
        if (!test_transpose(c.outDim, c.inDim)) {
            all_ok = false;
        }
    }

    if (all_ok) {
        std::printf("All transpose tests passed.\n");
        return 0;
    }
    return 1;
}

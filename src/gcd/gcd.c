#include "gcd.h"

uint32_t gcd_u32(uint32_t a, uint32_t b)
{
    /* When a or b equal to 0, return the nonzero one */
    if (a == 0U) {
        return b;
    } else if (b == 0U) {
        return a;
    }

    /* a and b are even */
    if (((a & 1U) == 0U) && ((b & 1U) == 0U)) {
        return gcd_u32(a >> 1, b >> 1) << 1;
    }

    /* One of a, b is odd, the other is even */
    if (((a & 1U) == 0U) && ((b & 1U) == 1U)) {
        return gcd_u32(a >> 1, b);
    } else if (((a & 1U) == 1U) && ((b & 1U) == 0U)) {
        return gcd_u32(a, b >> 1);
    }

    /* Both of a, b are odd */
    uint32_t a_minus_b, min;

    if (a > b) {
        a_minus_b = a - b;
        min = b;
    } else {
        a_minus_b = b - a;
        min = a;
    }

    return gcd_u32(a_minus_b, min);
}

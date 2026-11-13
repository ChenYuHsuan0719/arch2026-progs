#include "bf16.h"

/*
 * Narrow a binary32 pattern to BF16. Inf and NaN keep their top half.
 * Otherwise adding 0x7FFF plus bit 16 before dropping the low half rounds
 * to nearest with ties to even: a discarded half above 0x8000 always
 * carries, one below never does, and an exact half carries only when the
 * kept part is odd.
 */
uint16_t bf16_from_f32(uint32_t f32bits)
{
    /* Step 1: Inf and NaN pass through without rounding. */
    uint32_t exponent = f32bits >> 23;
    if ((exponent & 0XFF) == 0XFF) {
        return f32bits >> 16;
    }

    /* Step 2: round to nearest, ties to even, then keep the top half. */
    uint32_t add = f32bits + 0X7FFF;
    uint32_t bit_16 = (f32bits & 0X00010000) >> 16;
    uint32_t result = add + bit_16;
    return (result >> 16);
}

/*
 * Multiply two BF16 values. Inf and NaN are examined in the order a, then
 * b, as the contract requires, so Inf times NaN is Inf. Tiny operands are
 * normalized first, the 8-bit significands are multiplied, and the product
 * is truncated, not rounded. A result below the normal range keeps only
 * its 7-bit fraction shifted right, as the contract specifies.
 */
uint16_t bf16_mul(uint16_t a, uint16_t b)
{
    /* Step 0: split both operands into sign, exponent and fraction. */
    uint32_t sign = (a >> 15) ^ (b >> 15);
    uint32_t exponent_a = (a >> 7) & 0X00FF;
    uint32_t exponent_b = (b >> 7) & 0X00FF;
    uint32_t mantissa_a = a & 0X007F;
    uint32_t mantissa_b = b & 0X007F;

    /* Step 1: a is Inf or NaN. */
    if (exponent_a == 0X00FF) {
        if (mantissa_a != 0X0000) {
            return a;
        }
        if ((b & 0X7FFF) == 0X0000) {
            return 0X7FC0;
        }

        uint32_t inf = 0X7F80 | (sign << 15);
        return inf;
    }

    /* Step 2: b is Inf or NaN, examined only after a. */
    if (exponent_b == 0X00FF) {
        if (mantissa_b != 0X0000) {
            return b;
        }
        if ((a & 0X7FFF) == 0X0000) {
            return 0X7FC0;
        }

        uint32_t inf = 0X7F80 | (sign << 15);
        return inf;
    }

    /* Step 3: zero times a finite value is zero with the product sign. */
    if (((a & 0X7FFF) == 0X0000) || ((b & 0X7FFF) == 0X0000)) {
        uint32_t sign_0 = sign << 15;
        return sign_0;
    }

    /* Step 4: restore the leading one of normal operands. */
    if (exponent_a != 0X00000000) {
        mantissa_a += 0X00000080;
    }
    if (exponent_b != 0X00000000) {
        mantissa_b += 0X00000080;
    }

    /*
     * Step 4: normalize tiny operands. Their exponent field 0 stands for
     * the same power of two as 1, and every left shift of the significand
     * is paid back by one less in the exponent.
     */
    int32_t adjust_a = 0X00000000;
    int32_t adjust_b = 0X00000000;
    if (exponent_a == 0X00000000) {
        exponent_a = 0X00000001;

        while ((mantissa_a & 0X00000080) != 0X00000080) {
            adjust_a++;
            mantissa_a = mantissa_a << 1;
        }
    }
    if (exponent_b == 0X00000000) {
        exponent_b = 0X00000001;

        while ((mantissa_b & 0X00000080) != 0X00000080) {
            adjust_b++;
            mantissa_b = mantissa_b << 1;
        }
    }

    /*
     * Step 5: multiply the 8-bit significands. The product lies in
     * [2^14, 2^16); a product that reaches bit 15 is at least 2, so it is
     * shifted one more place and the exponent goes up by one. The bits
     * below the kept fraction are dropped, which truncates.
     */
    uint32_t mantissa_mul = mantissa_a * mantissa_b;
    int32_t adjust_15_of_exponent = 0X00000000;
    if ((mantissa_mul & 0X000008000) == 0X000008000) {
        mantissa_mul = mantissa_mul >> 1;
        adjust_15_of_exponent = 0X00000001;
    }
    mantissa_mul = mantissa_mul >> 7;
    uint32_t result_mantissa = mantissa_mul & 0X0000007F;

    /* Step 6: the stored exponents each carry the bias, so remove one. */
    int32_t result_exp = (int32_t) exponent_a + (int32_t) exponent_b - 127 -
                         adjust_a - adjust_b + adjust_15_of_exponent;

    /* Step 7: overflow gives Inf, deep underflow gives zero. */
    if (result_exp >= 0xFF) {
        uint32_t inf = 0X7F80 | (sign << 15);
        return inf;
    }
    if (result_exp < -6) {
        uint32_t sign_0 = sign << 15;
        return sign_0;
    }
    if (result_exp <= 0) {
        /*
         * NOTE: the contract shifts the 7-bit fraction, so the leading one
         * is dropped. IEEE 754 would shift the significand with it.
         */
        result_mantissa = result_mantissa >> (uint32_t) (1 - result_exp);
        return (sign << 15) | result_mantissa;
    }

    /* Step 8: assemble sign, exponent and fraction. */
    return (sign << 15) | ((uint32_t) result_exp << 7) | result_mantissa;
}

/*
 * Square root of a BF16 value. NaN, zero and the negative values are
 * decided before the sign is used, so that -NaN is returned unchanged and
 * -0 gives +0. The significand comes from the binary search of the quiz:
 * the largest mid with (mid * mid) / 128 <= m, which the truncating
 * division makes different from the largest mid with mid * mid <= 128 * m.
 */
uint16_t bf16_sqrt(uint16_t a)
{
    /* Step 0: split the operand into sign, exponent and fraction. */
    uint32_t sign_a = a >> 15;
    uint32_t exponent_a = (a >> 7) & 0X00FF;
    uint32_t mantissa_a = a & 0X007F;

    /*
     * Step 1: special values, in this order: NaN, zero, negative, +Inf,
     * tiny. NaN and zero come before the sign test, because -NaN is
     * returned unchanged and -0 gives +0.
     */
    if (exponent_a == 0xFF) {
        if (mantissa_a != 0) {
            return a;
        }
    }
    if ((a & 0X7FFF) == 0X0000) {
        return 0X0000;
    }
    if (sign_a == 0X00000001) {
        return 0x7FC0;
    }
    if (exponent_a == 0xFF) {
        return a;
    }
    if (exponent_a == 0x00000000) {
        return 0X0000;
    }

    /* Step 2: restore the leading one; m now lies in [128, 256). */
    mantissa_a = mantissa_a | 0X00000080;

    /*
     * Step 3: sqrt(2^e * m) = 2^(e / 2) * sqrt(m). An odd e cannot be
     * halved, so one factor of two moves into the significand, which then
     * lies in [256, 512). e may be negative, so it is halved with a
     * division, which is exact once e is even.
     */
    int32_t e = (int32_t) exponent_a - 127;
    if ((e % 2) != 0) {
        mantissa_a = mantissa_a << 1;
        e = e - 1;
    }
    e = e / 2;
    int32_t new_e = e + 127;

    /*
     * Step 4: binary search over [90, 256] for the largest mid with
     * (mid * mid) / 128 <= m. The window holds 167 candidates, so the
     * loop ends after at most 8 passes.
     */
    uint32_t low = 90, high = 256, result = 128;

    while (low <= high) {
        uint32_t mid = (low + high) >> 1;
        uint32_t sq = (mid * mid) / 128;

        if (sq <= mantissa_a) {
            result = mid;
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }

    /*
     * Step 5: keep the significand in [128, 256). The search never leaves
     * that range for a normal input, but the contract asks for the check.
     */
    if (result >= 256) {
        result = result >> 1;
        new_e += 1;
    }
    if (result < 128) {
        while (result > 90 && result < 128) {
            result = result << 1;
            new_e -= 1;
        }
    }

    /* Step 6: an exponent out of range gives Inf or zero. */
    if (new_e >= 0XFF) {
        return 0x7F80;
    }
    if (new_e <= 0) {
        return 0x0000;
    }

    /* Step 7: the result is positive, so there is no sign bit. */
    return ((uint32_t) new_e << 7) | (result & 0X0000007F);
}

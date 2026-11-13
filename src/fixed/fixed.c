#include "fixed.h"

/*
 * op1: a + b with bitwise operators. Each pass takes the carry word as the
 * shifted AND of the operands and the partial sum as their XOR, until the
 * carry word is zero; *n receives the number of passes.
 */
uint32_t op1(uint32_t a, uint32_t b, int *n)
{
    (*n) = 0;

    while (b != 0U) {
        uint32_t carry = (a & b) << 1;
        a = a ^ b;
        b = carry;
        (*n)++;
    }

    return a;
}

/* op2: a - b modulo 2^32; unsigned subtraction wraps by definition. */
uint32_t op2(uint32_t a, uint32_t b)
{
    return (a - b);
}

/*
 * op3: floor((a + b) / 2) without overflow. Since a + b = (a ^ b) +
 * 2 * (a & b), half of it is ((a ^ b) >> 1) + (a & b), which never exceeds
 * max(a, b).
 */
uint32_t op3(uint32_t a, uint32_t b)
{
    return ((a ^ b) >> 1) + (a & b);
}

/*
 * q_mul: Q11.20 product. A stored value A represents A / 2^20.
 *
 * Steps:
 *   1. Read a and b as unsigned and form the 64-bit unsigned product.
 *   2. Correct it to the signed product.
 *   3. Add 2^19, half a unit, so that the shift rounds.
 *   4. Keep bits 20 to 51 as the 32-bit result.
 * Ties round toward plus infinity, and a product outside the format wraps.
 */
int32_t q_mul(int32_t a, int32_t b)
{
    /*
     * Split each operand into 16-bit halves:
     *   unsign_a = aH * 2^16 + aL
     *   unsign_b = bH * 2^16 + bL
     * The operands are converted to unsigned first, so the right shift
     * fills with zeros and no bitwise operator touches a signed value.
     */
    uint32_t unsign_a = (uint32_t) a;
    uint32_t unsign_b = (uint32_t) b;
    uint32_t aH, bH;
    uint32_t aL, bL;

    aH = unsign_a >> 16U;
    bH = unsign_b >> 16U;
    aL = unsign_a & 0X0000FFFFU;
    bL = unsign_b & 0X0000FFFFU;

    /*
     * Step 1: the unsigned product.
     *   unsign_a * unsign_b = (aH * bH) * 2^32
     *                       + (aH * bL) * 2^16
     *                       + (aL * bH) * 2^16
     *                       + (aL * bL)
     * Each partial product of two 16-bit halves fits in 32 bits, so the
     * multiply stays in 32 bits and uses __mulsi3, never the 64-bit
     * __muldi3 that the runtime lacks. Each partial product is widened to
     * 64 bits before it is shifted, so no bit is lost.
     */
    uint64_t unsign_mul = (((uint64_t) (aH * bH)) << 32) +
                          (((uint64_t) (aH * bL)) << 16) +
                          (((uint64_t) (aL * bH)) << 16) + (uint64_t) (aL * bL);

    /*
     * Step 2: the signed product. A negative 32-bit value read as unsigned
     * is its signed value plus 2^32, so with sign_a = 1 when a < 0 and 0
     * otherwise:
     *   a = unsign_a - sign_a * 2^32
     *   b = unsign_b - sign_b * 2^32
     */
    uint32_t sign_a = (unsign_a & 0X80000000) >> 31;
    uint32_t sign_b = (unsign_b & 0X80000000) >> 31;

    /*
     * Multiplying out:
     *   a * b = unsign_a * unsign_b
     *         - sign_a * unsign_b * 2^32
     *         - sign_b * unsign_a * 2^32
     *         + sign_a * sign_b * 2^64
     * Modulo 2^64 the last term vanishes, and the two corrections only
     * change the high 32 bits. The subtraction is done on unsigned values
     * so that it wraps instead of overflowing.
     */
    uint64_t sign_mul = unsign_mul - ((uint64_t) (sign_a * unsign_b) << 32) -
                        ((uint64_t) (sign_b * unsign_a) << 32);

    /* Step 3: add half a unit, 2^19, so that the shift rounds. */
    uint64_t add_point_5 = sign_mul + 0X0000000000080000;

    /*
     * Step 4: keep bits 20 to 51. The bits an arithmetic shift would bring
     * in land above bit 31 of the result, so a logical shift of the
     * unsigned sum gives the same low 32 bits.
     */
    uint32_t result = add_point_5 >> 20;
    int32_t sign_result = result;

    return sign_result;
}

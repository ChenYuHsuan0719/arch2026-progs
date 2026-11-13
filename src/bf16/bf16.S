# BFloat16 routines: hand-written RV32I.
#
# uint16_t bf16_from_f32_asm(uint32_t f32bits)   a0 -> a0
# uint16_t bf16_mul_asm(uint16_t a, uint16_t b)  a0, a1 -> a0
# uint16_t bf16_sqrt_asm(uint16_t a)             a0 -> a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/tbf16.c.

    .macro NORMALIZE m, adj, t
    1:  
        andi    \t, \m, 0X00000080
        bnez    \t, 2f
        addi    \adj, \adj, 1
        slli    \m, \m, 1
        j       1b
    2:
    .endm

# MUL16 x, y, p, t: p = x * y for x, y below 2^16; x and y are destroyed
    .macro MUL32 x, y, p, t
        li      \p, 0
    1:
        andi    \t, \y, 1
        beqz    \t, 2f

        add     \p, \p, \x

    2:
        srli    \y, \y, 1
        slli    \x, \x, 1
        bnez    \y, 1b
        
    .endm

    .text

# bf16_from_f32_asm: narrow a binary32 pattern, rounding to nearest even.
# Registers:
#   a0  the binary32 pattern; the BF16 result on return
#   t0  the exponent field, then the rounding constant 0x7FFF
#   t1  the masked exponent, then a0 + 0x7FFF
#   t2  bit 16 of the input, the tie-breaking term
#   t3  the constant 0xFF
    .globl  bf16_from_f32_asm
    .type   bf16_from_f32_asm, @function
    .align  2
bf16_from_f32_asm:
    srli    t0, a0, 23      # uint32_t exponent = f32bits >> 23
    andi    t1, t0, 0XFF    # exponent & 0XFF
    li      t3, 0XFF
    beq     t1, t3, .Lfirst_if
    li      t0, 0X7FFF
    add     t1, a0, t0      # uint32_t add = f32bits + 0X7FFF   
    srli    t2, a0, 16      # uint32_t bit_16 = (f32bits & 0X00010000) >> 16
    andi    t2, t2, 1      # f32bits & 0X00010000
    add     a0, t1, t2      # uint32_t result = add + bit_16
    srli    a0, a0, 16      # result >> 16
    ret

.Lfirst_if:
    srli    a0, a0, 16
    ret
    .size   bf16_from_f32_asm, .-bf16_from_f32_asm

# bf16_mul_asm: BF16 product, truncated; Inf and NaN examined a first.
# Registers:
#   a0, a1  a and b; a0 is the result on return
#   t0      the product sign
#   t1, t2  exponent_a and exponent_b
#   t3, t4  mantissa_a and mantissa_b; later the fraction and the exponent
#   t5      the significand product
#   a2, a3  masks, constants and scratch
#   a4, a5  the left shifts that normalized a and b
#   a6      one when the product reached bit 15, else zero
    .globl  bf16_mul_asm
    .type   bf16_mul_asm, @function
    .align  2
bf16_mul_asm:
    # Get sign、exp、mantissa
    srli    t0, a0, 15
    srli    t1, a1, 15
    xor     t0, t0, t1     # sign = (a >> 15) ^ (b >> 15)
    srli    t1, a0, 7       # a >> 7
    andi    t1, t1, 0X00FF      # exponent_a = (a >> 7) & 0X00FF
    srli    t2, a1, 7       # b >> 7
    andi    t2, t2, 0X00FF      # exponent_b = (b >> 7) & 0X00FF;
    andi    t3, a0, 0X007F      # mantissa_a = a & 0X007F
    andi    t4, a1, 0X007F      # mantissa_b = b & 0X007F
    # Check exponent_a
    li      a2, 0X00FF
    bne     t1, a2, .Lcheck_exp_b_eqaul_0X00FF
    # Check mantissa_a
    # mantissa_a != 0X0000
    bnez    t3, .Lret_a     # return a
    li      a3, 0X7FFF
    and     a2, a1, a3      # b & 0X7FFF
    beqz    a2, .Lret_0X7FC0     
    j       .Lret_inf

.Lcheck_exp_b_eqaul_0X00FF:
    li      a3, 0X00FF
    bne     t2, a3, .Lnot_special
    # Check mantissa_b
    bnez    t4, .Lret_b     # return b
    li      a3, 0X7FFF
    and     a2, a0, a3      # a & 0X7FFF
    beqz    a2, .Lret_0X7FC0     
    j       .Lret_inf

.Lnot_special:
    li      a3, 0X7FFF
    and     a2, a0, a3      # (a & 0X7FFF)
    beqz    a2, .Lret_sign_0
    and     a2, a1, a3
    beqz    a2, .Lret_sign_0
    beqz    t1, .Lcheck_exp_b_and_decide_mantissa_b
    addi    t3, t3, 0X00000080



.Lcheck_exp_b_and_decide_mantissa_b:
    beqz    t2, .Ladjust
    addi    t4, t4, 0X00000080

.Ladjust:
    li      a4, 0
    # check_exp_a_eqaul_0 
    bnez    t1, .Lcheck_exp_b_eqaul_0
    addi    t1, t1, 0X00000001      # exponent_a = 0X00000001
    NORMALIZE t3, a4, a3 
    
.Lcheck_exp_b_eqaul_0:
    li      a5, 0
    bnez    t2, .Lmantissa_mul
    addi    t2, t2, 0X00000001      # exponent_b = 0X00000001
    NORMALIZE t4, a5, a3

.Lmantissa_mul:
    MUL32   t3, t4, t5, a3      # mantissa_mul = mantissa_a * mantissa_b
    li      a6, 0       # adjust_15_of_exponent = 0X00000000
    li      a3, 0X000008000
    and     t4, a3, t5
    bne     t4, a3, .Lmantissa_mul_shift_right_7
    srli    t5, t5, 1       # mantissa_mul = mantissa_mul >> 1
    li      a6, 0X00000001      # adjust_15_of_exponent = 0X00000001

.Lmantissa_mul_shift_right_7:
    srli    t5, t5, 7       # mantissa_mul = mantissa_mul >> 7
    andi    t3, t5, 0X0000007F      # result_mantissa = mantissa_mul & 0X0000007F
    add     t4, t1, t2      # (int32_t)exponent_a + (int32_t)exponent_b
    addi    t4, t4, -127    # (int32_t)exponent_a + (int32_t)exponent_b - 127
    sub     t4, t4, a4      # result_exp = (int32_t)exponent_a + (int32_t)exponent_b - 127 - adjust_a
    sub     t4, t4, a5      # result_exp = (int32_t)exponent_a + (int32_t)exponent_b - 127 - adjust_a  - adjust_b
    add     t4, t4, a6      # result_exp = (int32_t)exponent_a + (int32_t)exponent_b - 127 - adjust_a  - adjust_b + adjust_15_of_exponent
    
    # Check result_exp greater or equal 0xFF
    li      t5, 0xFF
    blt     t4, t5, .Lcheck_result_exp_smaller_than_neg_6
    j       .Lret_inf
        
.Lcheck_result_exp_smaller_than_neg_6:
    li      t5, -6
    bge     t4, t5, .Lcheck_result_exp_smaller_equal_0
    j       .Lret_sign_0
    
.Lcheck_result_exp_smaller_equal_0:
    bgtz    t4, .Lret_final     
    li      t5, 1
    sub     t5, t5, t4
    srl     t3, t3, t5      # result_mantissa = result_mantissa >> (uint32_t)(1 - result_exp)
    slli    t0, t0, 15      # sign << 15
    or      a0, t0, t3      # return (sign << 15) | result_mantissa
    ret

.Lret_final:
    slli    t0, t0, 15      # sign << 15
    slli    t4, t4, 7       # ((uint32_t)result_exp << 7)
    or      a0, t0, t4       # (sign << 15) | ((uint32_t)result_exp << 7)
    or      a0, a0, t3      # return (sign << 15) | ((uint32_t)result_exp << 7) | result_mantissa;
    ret

.Lret_inf:
    li      a3, 0X7F80
    slli    a2, t0, 15
    or      a2, a2, a3      # inf = 0X7F80 | (sign << 15)
    mv      a0, a2
    ret

.Lret_sign_0:
    slli    t0, t0, 15
    mv      a0, t0
    ret

.Lret_a:
    ret

.Lret_b:
    mv  a0, a1
    ret

.Lret_0X7FC0:
    li      a0, 0X7FC0
    ret
    .size   bf16_mul_asm, .-bf16_mul_asm


# bf16_sqrt_asm: BF16 square root with the binary search of the quiz.
# Registers:
#   a0      a; the result on return
#   t0      the sign of a
#   t1      the exponent field, then e, then the new exponent field
#   t2      the fraction, then the significand m
#   t3, t4  low and high of the search
#   t5      the best mid so far, the result significand
#   a1      constants, then mid
#   a2, a5  copies of mid for MUL32
#   a3      mid * mid, then divided by 128
#   a4      MUL32 scratch, then constants
    .globl  bf16_sqrt_asm
    .type   bf16_sqrt_asm, @function
    .align  2
bf16_sqrt_asm:
    # Get sign、exp、mantissa
    srli    t0, a0, 15
    srli    t1, a0, 7       # a >> 7
    andi    t1, t1, 0X00FF      # exponent_a = (a >> 7) & 0X00FF
    andi    t2, a0, 0X007F      # mantissa_a = a & 0X007F
    # Check exponent_a
    li      a1, 0X00FF
    bne     t1, a1, .Lcheck_a_and_0X7FFF
    # Check mantissa_a
    # mantissa_a != 0X0000
    bnez    t2, .Lsqrt_ret_a     # return a

.Lcheck_a_and_0X7FFF:
    li      a1, 0X7FFF
    and     a1, a0, a1
    bnez     a1, .Lcheck_sign_a_equal_0X00000001
    li      a0, 0X0000
    ret

.Lcheck_sign_a_equal_0X00000001:
    li      a1, 0X00000001
    bne     t0, a1, .Lcheck_exp_a_equal_0XFF
    li      a0, 0x7FC0
    ret

.Lcheck_exp_a_equal_0XFF:
    li      a1, 0XFF
    bne     t1, a1, .Lcheck_exp_a_equal_0
    ret

.Lcheck_exp_a_equal_0:
    bnez    t1, .Lmantissa_a
    li      a0, 0
    ret

.Lmantissa_a:
    ori     t2, t2, 0X00000080

    # exponent_a - 127
    li      a1, 127
    sub     t1, t1, a1      # e = (int32_t)exponent_a - 127
    andi    a2, t1, 0X00000001      # e % 2
    beqz    a2, .Le_div_2       # decide go to e = e / 2
    slli    t2, t2, 1       # mantissa_a = mantissa_a << 1
    addi    t1, t1, -1      # e = e - 1

.Le_div_2:
    srai    t1, t1, 1       # e = e / 2
    addi    t1, t1, 127     # new_e = e + 127
    li      t3, 90      # low = 90
    li      t4, 256     # high = 256
    li      t5, 128     # result = 128
    
.LBS_loop:
    bgt     t3, t4, .LBS_done
    add     a1, t3, t4      # mid
    srli    a1, a1, 1
    mv      a2, a1          # mid1
    mv      a5, a1          # mid2
    MUL32   a2, a5, a3, a4
    srli    a3, a3, 7
    bgt     a3, t2, .LBS_too_big
    # Too Small
    mv      t5, a1
    addi    t3, a1, 1
    j       .LBS_loop

.LBS_too_big:
    addi    t4, a1, -1
    j       .LBS_loop

.LBS_done:
    li      a4, 256
    blt     t5, a4 , .Lcheck_result_smaller_128
    srli    t5, t5, 1
    addi    t1, t1, 1

.Lcheck_result_smaller_128:
    li      a4, 128
    bge     t5, a4, .Lcheck_new_e_greater_equal_0XFF

.Lcheck_result_smaller_128_loop:
    li      a4, 90
    ble     t5, a4, .Lcheck_new_e_greater_equal_0XFF
    li      a4, 128
    bge     t5, a4, .Lcheck_new_e_greater_equal_0XFF
    slli    t5, t5, 1
    addi    t1, t1, -1
    j       .Lcheck_result_smaller_128_loop
    
.Lcheck_new_e_greater_equal_0XFF:
    li      a4, 0XFF
    blt     t1, a4, .Lcheck_new_e_smaller_equal_0
    li      a0, 0X7F80
    ret

.Lcheck_new_e_smaller_equal_0:
    bgtz    t1, .Lsqrt_ret_result
    li      a0, 0
    ret

.Lsqrt_ret_result:
    slli    t1, t1, 7
    andi    t5, t5, 0X0000007F
    or      a0, t1, t5
    ret

.Lsqrt_ret_a:
    ret


    
    .size   bf16_sqrt_asm, .-bf16_sqrt_asm

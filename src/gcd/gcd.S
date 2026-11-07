# gcd_u32_asm: binary GCD, hand-written RV32I.
#
# uint32_t gcd_u32_asm(uint32_t a, uint32_t b)   a in a0, b in a1, result in a0
#
# Algorithm:
#   1. gcd(0, b) = b and gcd(a, 0) = a.
#   2. k = trailing zeros of (a | b), the factors of two shared by a and b.
#   3. Strip the factors of two from a, so a is odd.
#   4. Loop: strip b to odd, swap so that a <= b, b = b - a, until b == 0.
#   5. Return a << k.
#
# Registers:
#   a0  a; odd after step 3; the result on return
#   a1  b
#   t0  a | b, shifted right while counting k
#   t1  lowest bit of the value being tested
#   t2  swap temporary
#   t3  k
#
# No stack frame and no saved registers: only a0, a1 and t0-t3 are used.
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/tgcd.c.

    .text

    .globl  gcd_u32_asm
    .type   gcd_u32_asm, @function
    .align  2
gcd_u32_asm:
    # Step 1: a zero operand returns the other one
    beq     a0, x0, .Lret_b     # If a == 0, gcd(0, b) = b, go to .Lret_b
    beq     a1, x0, .Lret_a     # If b == 0, gcd(a, 0) = a, go to .Lret_a

    # Step 2: count k, the trailing zeros of a | b
    or      t0, a0, a1          # a bit of a | b is 0 only if it is 0 in both
    li      t3, 0               # k = 0

.Lcount_the_num_of_0_that_a_and_b_both_have:
    andi    t1, t0, 1           # lowest bit of a | b
    bnez    t1, .Lshift_a_to_odd    # If t1 != 0 (t0's LSB is 1 / t0 is odd), no need to count and go to .Lshift_a_to_odd

.Lcount_loop:
    srli    t0, t0, 1           # drop one shared trailing zero
    andi    t1, t0, 1           # lowest bit of the shifted a | b
    addi    t3, t3, 1           # k++
    beqz    t1, .Lcount_loop    # If t1 == 0 (t0's LSB is 0 / t0 is even), still need to shift and count

    # Step 3: shift a right until it is odd
.Lshift_a_to_odd:
    andi    t1, a0, 1           # lowest bit of a
    bnez    t1, .Lshift_b_to_odd    # If t1 != 0 (a's LSB is 1 / a is odd), shift a to odd is already done and go to .Lshift_b_to_odd

.Lshift_a_loop:
    srli    a0, a0, 1           # drop one factor of two from a
    andi    t1, a0, 1           # lowest bit of the shifted a
    beqz    t1, .Lshift_a_loop  # If t1 == 0 (a's LSB is 0 / a is even), still need to shift a

    # Step 4: reduce b against the odd a until b is zero
.Lshift_b_to_odd:
    andi    t1, a1, 1           # lowest bit of b
    bnez    t1, .Lcompare       # If t1 != 0 (b's LSB is 1 / b is odd), no need to shift and go to .Lcompare

.Lshift_b_loop:
    srli    a1, a1, 1           # drop one factor of two from b; a is odd, so it is not shared
    andi    t1, a1, 1           # lowest bit of the shifted b
    beqz    t1, .Lshift_b_loop  # If t1 == 0 (b's LSB is 0 / b is even), still need to shift b

.Lcompare:
    bgtu    a0, a1, .Lshift_a_and_b     # If a > b (unsigned compare), go to .Lshift_a_and_b to swap a and b

.Lno_need_shift:
    sub     a1, a1, a0          # b = b - a; odd minus odd is even
    bnez    a1, .Lshift_b_to_odd    # If b != 0, go to .Lshift_b_to_odd for the next round
    beqz    a1, .Lret_a_shift_left_k_bits   # If b == 0 (always taken here), a is the odd gcd, go to .Lret_a_shift_left_k_bits

.Lshift_a_and_b:
    mv      t2, a0              # t2 = a, keep a before it is overwritten
    mv      a0, a1              # a = b, the smaller one
    mv      a1, t2              # b = old a, the larger one
    sub     a1, a1, a0          # b = b - a; odd minus odd is even
    bnez    a1, .Lshift_b_to_odd    # If b != 0, go to .Lshift_b_to_odd for the next round
    beqz    a1, .Lret_a_shift_left_k_bits   # If b == 0 (always taken here), a is the odd gcd, go to .Lret_a_shift_left_k_bits

    # Step 5: restore the shared factors of two
.Lret_a_shift_left_k_bits:
    sll     a0, a0, t3          # a = a << k, put back the k shared factors of two
    ret                         # return a

.Lret_b:
    mv      a0, a1              # a = b, the result goes back in a0
    ret                         # return b
.Lret_a:
    ret                         # a0 already holds a, return a
    .size   gcd_u32_asm, .-gcd_u32_asm

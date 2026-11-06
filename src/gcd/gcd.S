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
    beq     a0, x0, .Lret_b     # gcd(0, b) = b
    beq     a1, x0, .Lret_a     # gcd(a, 0) = a

    # Step 2: count k, the trailing zeros of a | b
    or      t0, a0, a1          # a bit of a | b is 0 only if it is 0 in both
    li      t3, 0               # k = 0

.Lcount_the_num_of_0_that_a_and_b_both_have:
    andi    t1, t0, 1           # lowest bit of a | b
    bnez    t1, .Lshift_a_to_odd    # it is 1: no more shared factors of two
    srli    t0, t0, 1           # drop one shared trailing zero
    addi    t3, t3, 1           # k++
    j       .Lcount_the_num_of_0_that_a_and_b_both_have

    # Step 3: shift a right until it is odd
.Lshift_a_to_odd:
    andi    t1, a0, 1           # lowest bit of a
    bnez    t1, .Lshift_b_to_odd    # a is odd
    srli    a0, a0, 1           # drop one factor of two from a
    beqz    t1, .Lshift_a_to_odd    # always taken: t1 is 0 here

    # Step 4: reduce b against the odd a until b is zero
.Lshift_b_to_odd:
    andi    t1, a1, 1           # lowest bit of b
    bnez    t1, .Lcompare       # b is odd
    srli    a1, a1, 1           # a is odd, so this factor of two is not shared
    beqz    t1, .Lshift_b_to_odd    # always taken: t1 is 0 here

.Lcompare:
    bgtu    a0, a1, .Lshift_a_and_b     # unsigned compare: swap when a > b

.Lno_need_shift:
    sub     a1, a1, a0          # b - a; odd minus odd is even
    bnez    a1, .Lshift_b_to_odd    # b != 0: next round
    beqz    a1, .Lret_a_shift_left_k_bits   # always taken: b == 0

.Lshift_a_and_b:
    mv      t2, a0              # swap a and b so that a <= b
    mv      a0, a1
    mv      a1, t2
    sub     a1, a1, a0          # b - a; odd minus odd is even
    bnez    a1, .Lshift_b_to_odd    # b != 0: next round
    beqz    a1, .Lret_a_shift_left_k_bits   # always taken: b == 0

    # Step 5: restore the shared factors of two
.Lret_a_shift_left_k_bits:
    sll     a0, a0, t3          # a << k
    ret

.Lret_b:
    mv      a0, a1              # return b
    ret
.Lret_a:
    ret                         # a0 already holds a
    .size   gcd_u32_asm, .-gcd_u32_asm

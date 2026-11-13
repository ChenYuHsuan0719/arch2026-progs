# op1, op2, op3 and q_mul: hand-written RV32I.
#
# uint32_t op1_asm(uint32_t a, uint32_t b, int *n)   a0, a1, a2 -> a0
# uint32_t op2_asm(uint32_t a, uint32_t b)           a0, a1 -> a0
# uint32_t op3_asm(uint32_t a, uint32_t b)           a0, a1 -> a0
# int32_t  q_mul_asm(int32_t a, int32_t b)           a0, a1 -> a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. q_mul forms a 64-bit product in a register pair. Tests:
# tests/tfixed.c.

# MUL16 x, y, p, t: p = x * y by shift and add, for x and y below 2^16, so
# the product fits in 32 bits. x and y are destroyed, and t is a scratch
# register. The loop ends as soon as y runs out of set bits.
    .macro MUL16 x, y, p, t
        li      \p, 0
    1:
        andi    \t, \y, 1           # lowest bit of the multiplier
        beqz    \t, 2f              # zero: nothing to add this round

        add     \p, \p, \x          # add the shifted multiplicand

    2:
        srli    \y, \y, 1           # next bit of the multiplier
        slli    \x, \x, 1           # multiplicand times two
        bnez    \y, 1b              # set bits left: keep going

    .endm

    .text

# op1_asm: a + b with bitwise operators; the number of passes goes to *n.
# Registers:
#   a0  a, the partial sum; the result on return
#   a1  b, the carry word; the loop ends when it is zero
#   a2  n, the address the pass count is stored to
#   t0  the bits where both a and b are 1
#   t1  the pass count, kept in a register and stored once at the end
    .globl  op1_asm
    .type   op1_asm, @function
    .align  2
op1_asm:
    add     t1, x0, x0              # pass count = 0
    beqz    a1, .Lop1_ret           # b == 0: no pass, store 0 and return a

.Lop1_loop:
    and     t0, a0, a1              # bits that produce a carry
    xor     a0, a0, a1              # a = a ^ b, the sum without carries
    slli    a1, t0, 1               # b = (a & b) << 1; the old b is no longer needed
    addi    t1, t1, 1               # one more pass
    bnez    a1, .Lop1_loop          # carries left: next pass

.Lop1_ret:
    sw      t1, 0(a2)               # *n = pass count
    ret
    .size   op1_asm, .-op1_asm

# op2_asm: a - b modulo 2^32.
# Registers:
#   a0  a; the result on return
#   a1  b
    .globl  op2_asm
    .type   op2_asm, @function
    .align  2
op2_asm:
    sub     a0, a0, a1              # wraps modulo 2^32, as the contract asks
    ret
    .size   op2_asm, .-op2_asm

# op3_asm: floor((a + b) / 2) without overflow.
# a + b = (a ^ b) + 2 * (a & b), so the half is ((a ^ b) >> 1) + (a & b),
# which never exceeds max(a, b).
# Registers:
#   a0  a; the result on return
#   a1  b
#   t0  (a ^ b) >> 1
#   t1  a & b
    .globl  op3_asm
    .type   op3_asm, @function
    .align  2
op3_asm:
    xor     t0, a0, a1              # bits where exactly one operand is 1
    srli    t0, t0, 1               # half of them, rounded down; logical shift
    and     t1, a0, a1              # bits where both are 1: already half of 2 * (a & b)
    add     a0, t0, t1              # cannot overflow
    ret
    .size   op3_asm, .-op3_asm

# q_mul_asm: Q11.20 product, rounded half up, low 32 bits of the shift.
# The 64-bit product is formed from four 16-bit partial products, corrected
# for the signs of a and b, rounded by adding 2^19, and bits 20 to 51 are
# returned.
# Registers:
#   a0, a1  a and b, kept to the end for the sign correction; a0 = result
#   t0, t1  aH and bH; later the high half of mid, and hi
#   t3, t4  aL and bL; later carries, the sign mask of a, a correction
#           term and the rounding constant
#   a2, a3  copies of the operands for MUL16; later mid and lo, the carry
#           of mid, and the sign mask of b
#   a4-a7   the partial products aL*bL, aL*bH, aH*bL, aH*bH
#   t2      scratch inside MUL16
    .globl  q_mul_asm
    .type   q_mul_asm, @function
    .align  2
q_mul_asm:
    # Split each operand into 16-bit halves
    srli    t0, a0, 16              # aH = a >> 16, logical
    srli    t1, a1, 16              # bH = b >> 16, logical
    slli    t3, a0, 16              # aL: push the high half out...
    srli    t3, t3, 16              # ...and bring the low half back down
    slli    t4, a1, 16              # bL, the same way
    srli    t4, t4, 16

    # Four partial products; MUL16 destroys its inputs, so copy them first
    mv      a2, t3
    mv      a3, t4
    MUL16   a2, a3, a4, t2          # a4 = aL * bL

    mv      a2, t3
    mv      a3, t1
    MUL16   a2, a3, a5, t2          # a5 = aL * bH

    mv      a2, t0
    mv      a3, t4
    MUL16   a2, a3, a6, t2          # a6 = aH * bL

    mv      a2, t0
    mv      a3, t1
    MUL16   a2, a3, a7, t2          # a7 = aH * bH

    # mid = aL * bH + aH * bL may need 33 bits
    add     a2, a5, a6
    bgeu    a2, a5, .Lno_overflow_for_mid   # the sum is not smaller: no carry
    addi    a3, x0, 1               # carry of mid, worth 2^48

.Lget_High_Low_bit:
    srli    t0, a2, 16              # high half of mid goes to hi
    slli    a2, a2, 16              # low half of mid goes to lo

    # lo = (mid << 16) + aL * bL, and its carry
    add     a2, a2, a4
    bgeu    a2, a4, .Lno_overflow_for_Lo    # the sum is not smaller: no carry
    addi    t3, x0, 1               # carry of lo into hi

.Lget_Hi:
    add     t1, a7, t0              # hi = aH * bH + high half of mid
    slli    a3, a3, 16              # carry of mid lands at bit 16 of hi
    add     t1, t1, a3
    add     t1, t1, t3              # plus the carry of lo
    j       .Lsign_fix

.Lno_overflow_for_mid:
    add     a3, x0, x0              # no carry of mid
    j       .Lget_High_Low_bit

.Lno_overflow_for_Lo:
    add     t3, x0, x0              # no carry of lo
    j       .Lget_Hi

.Lsign_fix:
    # A negative operand read as unsigned is its value plus 2^32, so the
    # signed product subtracts the other operand from hi for each negative
    # one. The masks from the arithmetic shifts replace a multiply.
    srai    t3, a0, 31              # all ones when a < 0, else zero
    and     t4, t3, a1              # b when a < 0, else zero
    sub     t1, t1, t4              # hi -= b
    srai    a3, a1, 31              # all ones when b < 0, else zero
    and     t4, a0, a3              # a when b < 0, else zero
    sub     t1, t1, t4              # hi -= a

    # Add 2^19, half a unit, so that the shift rounds
    li      t4, 0x80000             # does not fit a 12-bit immediate
    add     a2, a2, t4              # lo += 2^19
    bgeu    a2, t4, .Lno_overflow_for_add_offset    # no carry into hi
    addi    t3, x0, 1               # carry of the rounding into hi

.Ltake_out_result:
    add     t1, t1, t3              # hi += carry

    # Bits 20 to 51 of the 64-bit sum: 20 bits of hi above 12 bits of lo
    slli    t1, t1, 12              # bits 0 to 19 of hi become bits 12 to 31
    srli    a2, a2, 20              # bits 20 to 31 of lo become bits 0 to 11

    or      a0, t1, a2
    ret

.Lno_overflow_for_add_offset:
    add     t3, x0, x0              # no carry of the rounding
    j       .Ltake_out_result

    .size   q_mul_asm, .-q_mul_asm

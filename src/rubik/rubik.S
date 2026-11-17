# rubik_solve_asm: optimal 2x2x2 cube solver, hand-written RV32I.
#
# int rubik_solve_asm(const char *state, char *out, size_t cap)
#                                   a0 = state, a1 = out, a2 = cap; result in a0
#
# Returns the number of moves of a shortest solution and writes it into out,
# -1 for an invalid state, -2 when the text does not fit in cap bytes.
#
# The algorithm is the one of the C version: parse and check the state, index
# it as a permutation p (Lehmer code, 0 to 5039) and an orientation o (base 3,
# 0 to 728), run IDA* with the larger of two pattern databases as the
# heuristic, then write the moves.
#
# Stack frame, 224 bytes, 16-byte aligned:
#   sp +   0  s.p[0..6]       the parsed permutation, one byte per cubie
#   sp +   7  s.o[0..6]       the parsed orientations
#   sp +  16  path[0..10]     the move made at each depth
#   sp +  32  last_face[d]    the face that led to depth d (3: none)
#   sp +  48  next[d]         the next move to try at depth d
#   sp +  64  sp_[d]          halfword: the permutation at depth d
#   sp +  96  so_[d]          halfword: the orientation at depth d
#   sp + 128  cp[d]           halfword: the permutation of the child tried
#   sp + 160  co[d]           halfword: the orientation of the child tried
#   sp + 192  s0 to s5        saved on entry, restored on every return
#
# Registers:
#   a0      state on entry; the result on return
#   a1      out, advanced while the moves are written
#   a2      cap
#   a3      parse cursor; then the IDA* bound
#   a4, a5  p and o of the start; later scratch inside HEUR
#   a6      d, the current depth
#   a7      min, the smallest f cut in this round
#   t0-t6   scratch; in the search t0 = move, t3 = face, t4 = sp + 2d,
#           t5 = sp + d, t6 and t2 = the child's p and o
#   s0, s1  pdb_p and pdb_o
#   s2, s3  the tables of perm_move[face] and ori_move[face]
#   s4, s5  move_face and move_turn
#
# No calls: the function is a leaf, keeps no saved register and needs no
# return address on the stack.
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions, no heap, no recursion. Tests: tests/trubik.c.

# HEUR dist, p, o, temp_a, temp_b: dist = max(pdb_p[p], pdb_o[o]), the
# heuristic. Each pattern database is a lower bound on the distance, so their
# maximum is one too. temp_a and temp_b are scratch registers.
    .macro HEUR dist, p, o, temp_a, temp_b
        add     \temp_a, s0, \p         # s0 = pdb_p
        lbu     \dist, 0(\temp_a)
        add     \temp_a, s1, \o         # s1 = pdb_o
        lbu     \temp_b, 0(\temp_a)
        bgeu    \dist, \temp_b, 1f       # keep the larger lower bound
        mv      \dist, \temp_b
    1:
    .endm

    .section .rodata
    .balign 4
.Lperm_tab:                         # perm_move[face]
    .word   rubik_tab_perm_move_R, rubik_tab_perm_move_B, rubik_tab_perm_move_D
.Lori_tab:                          # ori_move[face]
    .word   rubik_tab_ori_move_R, rubik_tab_ori_move_B, rubik_tab_ori_move_D
.Lmove_face:                        # move / 3, without a divider
    .byte   0, 0, 0, 1, 1, 1, 2, 2, 2
.Lmove_turn:                        # move % 3, without a divider
    .byte   0, 1, 2, 0, 1, 2, 0, 1, 2
.Lname_first:                       # first character of each move name
    .byte   82, 82, 82, 66, 66, 66, 68, 68, 68      # R R R B B B D D D
.Lname_second:                      # second character, 0 when there is none
    .byte   0, 50, 39, 0, 50, 39, 0, 50, 39         # - 2 ' - 2 ' - 2 '

    .text

    .globl  rubik_solve_asm
    .type   rubik_solve_asm, @function
    .align  2
rubik_solve_asm:
    addi    sp, sp, -224        # 192 for the arrays, 32 for s0 to s5
    sw      s0, 192(sp)         # callee-saved: restore before returning
    sw      s1, 196(sp)
    sw      s2, 200(sp)
    sw      s3, 204(sp)
    sw      s4, 208(sp)
    sw      s5, 212(sp)

    # Step 1: parse. s.p[0..6] at sp + 0, s.o[0..6] at sp + 7. A digit minus
    # '1' is compared unsigned with the count of allowed values, so one
    # branch rejects both a digit that is too large and one below '1': a
    # character below '1', the terminating zero included, wraps to a huge
    # value. A string that ends early therefore stops here, and nothing past
    # its end is read.
    mv      a3, a0              # a3: cursor into the state text
    mv      t2, sp              # t2: where the next digit is stored
    addi    t5, sp, 7           # t5: end of s.p
    li      t1, 7               # a permutation digit is 0 to 6 after '1'

.Lparse_state_perm:
    lbu     t0, 0(a3)
    addi    t0, t0, -49         # '1' becomes 0
    bgeu    t0, t1, .Linvalid_state
    sb      t0, 0(t2)
    addi    a3, a3, 1
    addi    t2, t2, 1
    bne     t2, t5, .Lparse_state_perm

    addi    t5, sp, 14          # t5: end of s.o
    li      t1, 3               # an orientation digit is 0 to 2 after '1'
.Lparse_state_ori:
    lbu     t0, 0(a3)
    addi    t0, t0, -49
    bgeu    t0, t1, .Linvalid_state
    sb      t0, 0(t2)
    addi    a3, a3, 1
    addi    t2, t2, 1
    bne     t2, t5, .Lparse_state_ori

    lbu     t0, 0(a3)           # exactly 14 characters
    bnez    t0, .Linvalid_state

    # Step 2: each cubie exactly once, and orientations summing to a
    # multiple of 3. One bit per cubie replaces the pairwise comparison of
    # the C version: 7 tests instead of 21.
    li      t3, 0               # t3: seen, bit k set when cubie k appeared
    li      t4, 0               # t4: orientation sum
    li      t6, 0               # t6: index i
    li      t1, 1

.Lcheck_valid:
    add     t2, sp, t6
    lbu     t0, 0(t2)           # s.p[i]
    sll     t0, t1, t0          # the bit of this cubie, 1 << s.p[i]
    and     t5, t3, t0
    bnez    t5, .Linvalid_state # already seen: a repeated cubie
    or      t3, t3, t0          # record it
    lbu     t0, 7(t2)           # s.o[i]
    add     t4, t4, t0
    addi    t6, t6, 1
    li      t0, 7
    bne     t6, t0, .Lcheck_valid

    # The sum is at most 14, so subtraction replaces the missing remainder.
    li      t0, 3
.Lmod3_loop:
    bltu    t4, t0, .Lmod3_done # below 3: this is the remainder
    sub     t4, t4, t0
    j       .Lmod3_loop
.Lmod3_done:
    bnez    t4, .Linvalid_state # not a multiple of 3

    # Step 3a: o = s.o[0..5] read as a base-3 number. The seventh
    # orientation is implied by the other six, so it is left out.
    li      a5, 0               # a5: o
    addi    t2, sp, 7           # t2: &s.o[0]
    addi    t5, sp, 13          # t5: stop after s.o[5]
.Lrank_ori:
    slli    t0, a5, 1
    add     a5, a5, t0          # o * 3 = (o << 1) + o, no multiply
    lbu     t0, 0(t2)
    add     a5, a5, t0          # + s.o[i]
    addi    t2, t2, 1
    bne     t2, t5, .Lrank_ori

    # Step 3b: p = Lehmer code of s.p[0..6]. For each position, count the
    # later cubies that are smaller, then p = p * (7 - i) + smaller. The
    # multiplier is at most 7, so repeated addition replaces the multiply.
    li      a4, 0               # a4: p
    li      t6, 0               # t6: i
    li      t3, 7               # t3: 7 - i, the weight of this digit
.Lrank_perm:
    add     t2, sp, t6
    lbu     t1, 0(t2)           # t1: s.p[i]
    li      t4, 0               # t4: smaller
    addi    t5, t6, 1           # t5: j = i + 1
.Lrank_count:
    add     t2, sp, t5
    lbu     t0, 0(t2)           # s.p[j]
    sltu    t0, t0, t1          # 1 when s.p[j] < s.p[i], with no branch
    add     t4, t4, t0
    addi    t5, t5, 1
    li      t0, 7
    bne     t5, t0, .Lrank_count

    mv      t0, t3              # t0: how many times to add p
    li      t2, 0               # t2: p * (7 - i)
.Lrank_shift_and_add:
    add     t2, t2, a4
    addi    t0, t0, -1
    bnez    t0, .Lrank_shift_and_add
    add     a4, t2, t4          # p = p * (7 - i) + smaller

    addi    t6, t6, 1           # next i
    addi    t3, t3, -1          # next weight
    li      t0, 6
    bne     t6, t0, .Lrank_perm # i = 6 would add nothing: times 1, plus 0

    # Step 4: IDA* on (p, o), a4 = p0, a5 = o0. An explicit stack on the
    # frame replaces the recursion: byte arrays at sp + d, halfword arrays at
    # sp + 2d. Going down a level writes slot d + 1 and increments d; going
    # back up decrements d.
    # The table addresses never change during the search, so they are
    # loaded once here instead of at every child.
    la      s0, rubik_tab_pdb_p
    la      s1, rubik_tab_pdb_o
    la      s2, .Lperm_tab
    la      s3, .Lori_tab
    la      s4, .Lmove_face
    la      s5, .Lmove_turn

    or      t0, a4, a5
    li      a0, 0               # length 0 when already solved
    beqz    t0, .Lsolved
    HEUR    a3, a4, a5, t0, t1  # the first bound is h of the start
    sh      a4, 64(sp)          # sp_[0] = p0, never overwritten
    sh      a5, 96(sp)          # so_[0] = o0

.Lida_while_loop:
    li      t0, 11              # the diameter
    bgtu    a3, t0, .Lida_return_UINT8_MAX     # cannot happen for a valid state

    li      a7, 255             # min = UINT8_MAX
    li      a6, 0               # d = 0
    li      t0, 3               # NO_FACE: the start has no previous face
    sb      t0, 32(sp)          # last_face[0]
    sb      x0, 48(sp)          # next[0] = 0

.Lida_for_loop:
    add     t5, sp, a6          # t5 = sp + d, for the byte arrays
    lbu     t0, 48(t5)          # t0 = next[d]
    li      t2, 9
    bne     t0, t2, .Lno_finish_of_9_move
    beqz    a6, .Lida_next_round    # all nine moves tried at depth 0
    addi    a6, a6, -1          # back to the parent
    j       .Lida_for_loop

.Lno_finish_of_9_move:
    addi    t1, t0, 1
    sb      t1, 48(t5)          # next[d] = move + 1
    add     t1, s4, t0
    lbu     t3, 0(t1)           # t3 = face
    lbu     t1, 32(t5)          # last_face[d]
    bne     t3, t1, .Lida_turn

    # Pruning: turning the same face twice in a row is never optimal, and
    # the three turns of a face are consecutive moves, so skip all three.
    addi    t1, t0, 3
    sb      t1, 48(t5)
    j       .Lida_for_loop

.Lida_turn:
    slli    t4, a6, 1
    add     t4, sp, t4          # t4 = sp + 2d, for the halfword arrays
    add     t1, s5, t0
    lbu     t1, 0(t1)
    bnez    t1, .Lida_apply     # X2 and X' turn the previous child again
    lhu     t1, 64(t4)
    sh      t1, 128(t4)         # the quarter turn starts from the parent:
    lhu     t1, 96(t4)          # cp[d] = sp_[d], co[d] = so_[d]
    sh      t1, 160(t4)

.Lida_apply:
    # One quarter turn on each index, by table lookup.
    slli    t2, t3, 2           # face * 4, an index into a word table
    add     t1, s2, t2
    lw      t1, 0(t1)           # perm_move[face]
    lhu     t6, 128(t4)
    slli    t6, t6, 1           # a halfword table: index * 2
    add     t1, t1, t6
    lhu     t6, 0(t1)           # t6 = perm_move[face][cp[d]]
    sh      t6, 128(t4)         # cp[d] = t6
    add     t1, s3, t2
    lw      t1, 0(t1)           # ori_move[face]
    lhu     t2, 160(t4)
    slli    t2, t2, 1
    add     t1, t1, t2
    lhu     t2, 0(t1)           # t2 = ori_move[face][co[d]]
    sh      t2, 160(t4)         # co[d] = t2

    # f = g + h with g = d + 1. A child with f above the bound cannot be
    # solved within this round, so it is cut, and the smallest such f
    # becomes the next bound.
    HEUR    t1, t6, t2, a4, a5
    add     t1, t1, a6
    addi    t1, t1, 1           # f = d + 1 + h
    bleu    t1, a3, .Lida_accept    # f <= bound: go deeper
    bgeu    t1, a7, .Lida_for_loop  # f >= min: nothing to record
    mv      a7, t1              # min = f
    j       .Lida_for_loop

.Lida_accept:
    sb      t0, 16(t5)          # path[d] = move
    or      t1, t6, t2
    beqz    t1, .Lida_found     # p and o both 0: solved
    sh      t6, 66(t4)          # sp_[d + 1] = cp[d]
    sh      t2, 98(t4)          # so_[d + 1] = co[d]
    sb      t3, 33(t5)          # last_face[d + 1] = face
    sb      zero, 49(t5)        # next[d + 1] = 0
    addi    a6, a6, 1           # d++
    j       .Lida_for_loop

.Lida_next_round:
    # The bound grows to the smallest f cut, so no shorter solution is
    # skipped and the first solution found is a shortest one.
    mv      a3, a7
    j       .Lida_while_loop

.Lida_found:
    addi    a0, a6, 1           # length = d + 1
.Lsolved:
    # Step 5a: bytes needed = 1 for the NUL + every name + a space before
    # every move but the first. The length is checked before any byte is
    # written, so a buffer that is too small is never half filled.
    li      t0, 1               # t0: bytes needed
    li      t1, 0               # t1: i
    la      t3, .Lname_second
.Lneed_loop:
    beq     t1, a0, .Lneed_done
    add     t2, sp, t1
    lbu     t2, 16(t2)          # t2 = path[i]
    add     t2, t3, t2
    lbu     t2, 0(t2)           # second character, 0 when none
    addi    t0, t0, 1           # the first character
    beqz    t2, .Lneed_no_second
    addi    t0, t0, 1           # the second character
.Lneed_no_second:
    beqz    t1, .Lneed_no_space
    addi    t0, t0, 1           # the space before this move
.Lneed_no_space:
    addi    t1, t1, 1
    j       .Lneed_loop

.Lneed_done:
    # Step 5b: too small a buffer returns -2, with out[0] = 0 when cap >= 1
    bleu    t0, a2, .Lwrite     # needed <= cap: it fits
    beqz    a2, .Ltoo_small     # cap == 0: write nothing at all
    sb      zero, 0(a1)
.Ltoo_small:
    li      a0, -2
    j       .Lrubik_ret

.Lwrite:
    # Step 5c: copy the names; a1 walks through out
    li      t1, 0               # t1: i
    la      t4, .Lname_first
.Lwrite_loop:
    beq     t1, a0, .Lwrite_done
    beqz    t1, .Lwrite_name    # no space before the first move
    li      t2, 32              # ' '
    sb      t2, 0(a1)
    addi    a1, a1, 1
.Lwrite_name:
    add     t2, sp, t1
    lbu     t2, 16(t2)          # t2 = path[i]
    add     t5, t4, t2
    lbu     t5, 0(t5)
    sb      t5, 0(a1)           # first character
    addi    a1, a1, 1
    add     t5, t3, t2
    lbu     t5, 0(t5)
    beqz    t5, .Lwrite_next    # one-character name
    sb      t5, 0(a1)           # second character
    addi    a1, a1, 1
.Lwrite_next:
    addi    t1, t1, 1
    j       .Lwrite_loop
.Lwrite_done:
    sb      zero, 0(a1)         # terminate the string
    j       .Lrubik_ret         # a0 still holds the length

.Lida_return_UINT8_MAX:
    li      a0, -1
    j       .Lrubik_ret

.Linvalid_state:
    li      a0, -1
.Lrubik_ret:
    lw      s0, 192(sp)         # restore the callee-saved registers
    lw      s1, 196(sp)
    lw      s2, 200(sp)
    lw      s3, 204(sp)
    lw      s4, 208(sp)
    lw      s5, 212(sp)
    addi    sp, sp, 224         # restore the stack on every path
    ret
    .size   rubik_solve_asm, .-rubik_solve_asm

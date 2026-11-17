#include "rubik.h"
#include "rubik_tables.h"

enum {
    CUBIES = 7,
    PERMUTATIONS = 5040, /* 7! */
    ORIENTATIONS = 729,  /* 3^6 */
    STATES = PERMUTATIONS * ORIENTATIONS,
    MOVES = 9 /* three faces, three turns each */
};

typedef struct {
    uint8_t p[CUBIES], o[CUBIES];
} state_t;

static const char *const move_names[MOVES] = {"R",  "R2", "R'", "B", "B2",
                                              "B'", "D",  "D2", "D'"};

/*
 * Index a state without a division. The permutation gets its Lehmer code,
 * 0 to 5039: for each position, count the later cubies that are smaller, and
 * weight the counts by falling factorials. The orientations of the first six
 * cubies are read as a base-3 number, 0 to 728; the seventh is implied,
 * because the orientations sum to a multiple of 3. The two indices are kept
 * apart, since combining them would need a division by 729 to split them.
 */
static void rank_state(const state_t *state, uint16_t *p, uint16_t *o)
{
    uint32_t perm = 0, ori = 0;

    for (uint8_t i = 0; i < CUBIES; ++i) {
        /* smaller: the cubies after position i that are smaller than it */
        uint8_t smaller = 0;

        for (uint8_t j = (uint8_t) (i + 1U); j < CUBIES; ++j)
            if (state->p[j] < state->p[i])
                ++smaller;
        perm = perm * (CUBIES - i) + smaller;
    }

    for (uint8_t i = 0; i < 6; ++i)
        ori = ((ori << 1) + ori) + state->o[i]; /* ori * 3, no multiply */

    *p = (uint16_t) perm;
    *o = (uint16_t) ori;
}

/*
 * A real cube: every digit in range, every cubie exactly once, and the
 * orientations summing to a multiple of 3. The sum is at most 14, so it is
 * reduced by subtraction instead of the % operator, which would call a
 * division routine the runtime does not have.
 */
static int valid(const state_t *state)
{
    uint8_t sum = 0;

    for (uint8_t i = 0; i < CUBIES; ++i) {
        /* the range of each digit */
        if (state->p[i] >= CUBIES || state->o[i] >= 3)
            return 0;

        /* no repeated cubie */
        for (uint8_t j = 0; j < i; ++j)
            if (state->p[j] == state->p[i])
                return 0;

        sum = (uint8_t) (sum + state->o[i]);
    }

    while (sum >= 3) {
        sum = (uint8_t) (sum - 3U);
    }
    return sum == 0U;
}

/*
 * Exactly 14 characters: seven permutation digits '1' to '7', then seven
 * orientation digits '1' to '3'. A string that ends early fails the range
 * test at its terminating zero, so nothing past the end is read.
 */
static int parse_state(const char *input, state_t *state)
{
    for (int i = 0; i < CUBIES; ++i) {
        if (input[i] < '1' || input[i] > '7')
            return 0;

        state->p[i] = (uint8_t) (input[i] - '1');
    }

    for (int i = 0; i < CUBIES; ++i) {
        char c = input[i + CUBIES];
        if (c < '1' || c > '3')
            return 0;
        state->o[i] = (uint8_t) (c - '1');
    }
    return input[14] == '\0' && valid(state);
}

enum {
    MAX_DEPTH = 11, /* the diameter: every state is solved within 11 moves */
    NO_FACE = 3     /* the start has no previous face */
};

/* Tables replace move / 3 and move % 3, since RV32I has no divider. */
static const uint8_t move_face[MOVES] = {0, 0, 0, 1, 1, 1, 2, 2, 2};
static const uint8_t move_turn[MOVES] = {0, 1, 2, 0, 1, 2, 0, 1, 2};

static const uint16_t *const perm_move[3] = {perm_move_R, perm_move_B,
                                             perm_move_D};
static const uint16_t *const ori_move[3] = {ori_move_R, ori_move_B, ori_move_D};

static uint8_t path[MAX_DEPTH]; /* path[d] = the move made at depth d */

/*
 * Each pattern database is a lower bound on the distance: solving the cube
 * solves its permutation and its orientation. The larger of two lower bounds
 * is still a lower bound, so the heuristic is admissible.
 */
static uint8_t heuristic(uint16_t p, uint16_t o)
{
    return pdb_p[p] > pdb_o[o] ? pdb_p[p] : pdb_o[o];
}

/*
 * IDA*: a depth-first search that cuts every path whose f = g + h exceeds the
 * bound. When a whole round fails, the bound becomes the smallest f that was
 * cut, so no shorter solution is skipped and the first one found is optimal.
 *
 * The recursion is replaced by arrays indexed by the depth d, which keeps the
 * code free of recursion for the assembly version: going down a level writes
 * slot d + 1 and increments d, going back up decrements d.
 *
 * Returns the length of the solution, stored in path[0 .. length - 1], or
 * UINT8_MAX when none is found.
 */
static uint8_t ida_star(uint16_t p0, uint16_t o0)
{
    uint16_t sp[MAX_DEPTH + 1], so[MAX_DEPTH + 1]; /* the state at depth d */
    uint16_t cp[MAX_DEPTH + 1], co[MAX_DEPTH + 1]; /* the child being tried */
    uint8_t last_face[MAX_DEPTH + 1];              /* the face that led here */
    uint8_t next[MAX_DEPTH + 1];                   /* the next move to try */
    uint8_t bound = heuristic(p0, o0);

    if (p0 == 0 && o0 == 0)
        return 0;
    while (bound <= MAX_DEPTH) {
        uint8_t min = UINT8_MAX; /* the smallest f cut in this round */
        uint8_t d = 0;
        sp[0] = p0;
        so[0] = o0;
        last_face[0] = NO_FACE;
        next[0] = 0;

        for (;;) {
            if (next[d] == MOVES) { /* all nine moves tried: back up */
                if (d == 0)
                    break;
                --d;
                continue;
            }
            uint8_t move = next[d]++;
            uint8_t face = move_face[move];
            if (face == last_face[d]) {
                /*
                 * Turning the same face twice in a row is never optimal:
                 * R then R is R2, and R then R' does nothing. The three
                 * turns of a face are consecutive, so skip all of them.
                 */
                next[d] = (uint8_t) (move + 3U);
                continue;
            }
            /*
             * X, X2 and X' of one face are tried in order, and each turns the
             * previous child by another quarter turn, so the move tables only
             * need the quarter turn.
             */
            if (move_turn[move] == 0) {
                cp[d] = sp[d];
                co[d] = so[d];
            }
            cp[d] = perm_move[face][cp[d]];
            co[d] = ori_move[face][co[d]];
            uint8_t f = (uint8_t) (d + 1U + heuristic(cp[d], co[d]));
            if (f > bound) {
                if (f < min)
                    min = f;
                continue;
            }
            path[d] = move;
            if (cp[d] == 0 && co[d] == 0)
                return (uint8_t) (d + 1U);
            /* go down one level, where the recursion would call itself */
            sp[d + 1] = cp[d];
            so[d + 1] = co[d];
            last_face[d + 1] = face;
            next[d + 1] = 0;
            ++d;
        }
        bound = min; /* the next round allows the smallest f cut here */
    }
    return UINT8_MAX;
}

static const uint8_t move_len[MOVES] = {1, 2, 2, 1, 2, 2, 1, 2, 2};

/*
 * Solve a state and write the moves separated by single spaces. The length of
 * the text is checked against cap before any byte is written, so a buffer
 * that is too small gets only out[0] = '\0', and a zero-length one nothing.
 */
int rubik_solve(const char *state, char *out, size_t cap)
{
    state_t s;
    if (!parse_state(state, &s))
        return -1;

    uint16_t p, o;
    rank_state(&s, &p, &o);
    uint8_t length = ida_star(p, o);

    /* bytes needed: every name, a space before all but the first, the NUL */
    uint8_t byte_need = 1;
    for (uint8_t i = 0; i < length; i++) {
        if (i > 0)
            byte_need += 1;
        uint8_t move_index = path[i];
        byte_need += move_len[move_index];
    }

    if (byte_need > cap) {
        if (cap >= 1)
            out[0] = '\0';
        return -2;
    }

    size_t pos = 0;
    for (uint8_t i = 0; i < length; i++) {
        if (i > 0)
            out[pos++] = ' '; /* space between moves */
        const char *name = move_names[path[i]];
        for (uint8_t k = 0; name[k] != '\0'; k++)
            out[pos++] = name[k]; /* copy the move name */
    }
    out[pos] = '\0';
    return length;
}

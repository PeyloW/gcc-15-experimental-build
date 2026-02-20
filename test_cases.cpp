#define __forceinline __attribute__((__always_inline__)) inline
#define __assume_count(i, c) __attribute__((assume(i >= 0 && i < c)))

template<class T, class... Args>
__forceinline constexpr T* construct_at(T* p, Args&&... args) {
    *p = T(args...);
    return p;
}

template<typename T>
class vector_c {
public:
    static constexpr int max_count = 0x8000 / sizeof(T);
    
    __forceinline T& operator[](int i) {
        __assume_count(i, max_count);
        return _data[i];
    }
    __forceinline const T& operator[](int i) const {
        __assume_count(i, max_count);
        return _data[i];
    }
    
    __forceinline T& back() {
        int idx = _size - 1;
        [[assume(idx >= 0 && idx < max_count)]];
        return _data[idx];
    }

    template<class... Args>
    __forceinline T& emplace_back(Args&&... args) {
        int idx = _size++;
        [[assume(idx >= 0 && idx < max_count)]];
        return *construct_at(&_data[idx], (Args&&)args...);
    }
    
private:
    T *_data;
    unsigned _size;
};

extern "C" {
    
    
    /* test_dbra_mixed_counter - dbra loop with mixed-size counter
     * Optimizations:
     *   - Loop to dbra conversion: NOT applied due to mixed counter sizes
     *   - Post-increment addressing: move.w (%a0)+,(%a1)+ used for memory access
     * Observed: Loop uses cmp.l/jhi instead of dbra because unsigned short counter
     *   must be zero-extended to compare with unsigned int bound.
     * Responsible: m68k_reorg() doloop handling, m68k_reorg_postinc()
     * Savings at -O2: 0 cycles, 0 bytes (identical output)
     * Savings at -Os: ~16 cycles/iteration (indexed move.w d(an),d(an)=24 vs
     *   postinc move.w (an)+,(an)+=12), 4 bytes static
     */
    void test_dbra_mixed_counter(const short* src, short* dst, unsigned int count) {
        for (unsigned short i = 0; i < count; i++) {
            *dst++ = *src++;
        }
    }
    
    /* test_dbra_matching_counter - dbra loop with matching counter types
     * Optimizations:
     *   - Loop to dbra conversion: Converts pointer-compare loop to dbra instruction
     *   - Post-increment addressing: move.w (%a0)+,(%a1)+ for both src and dst
     * Observed: Saves 5 instructions by replacing and.l/add.l/add.l/cmp.l/jne
     *   sequence with single dbra instruction.
     * Responsible: m68k_reorg() doloop pattern matching, m68k_reorg_postinc()
     * Savings at -O2: ~38 cycles/iteration (and.l=20 + 2x add.l=12 + cmp.l=6 vs
     *   dbra=10), 8 bytes static (16 bytes setup vs 8 bytes with dbra)
     * Savings at -Os: ~18 cycles/iteration (indexed vs dbra+postinc), 10 bytes static
     */
    void test_dbra_matching_counter(const short* src, short* dst, unsigned short count) {
        for (long i = 0; i < count; i++) {
            dst[i] = src[i];
        }
    }
    
    /* test_dbra_const_count - dbra with constant iteration count
     * Optimizations:
     *   - Loop to dbra conversion: Uses moveq #49 + dbra instead of pointer compare
     *   - Post-increment addressing: move.w (%a0)+,(%a1)+ for memory access
     * Observed: Saves 2 instructions; uses count-1 (49) in moveq for dbra semantics,
     *   eliminating add.l for end pointer and cmp.l/jne loop control.
     * Responsible: m68k_reorg() doloop with constant bounds, m68k_reorg_postinc()
     * Savings at -O2: ~6 cycles/iteration (cmp.l + jne vs dbra), 4 bytes static
     * Savings at -Os: ~10 cycles/iteration (indexed + cmp vs dbra+postinc), 6 bytes
     */
    void test_dbra_const_count(const short* src, short* dst) {
        for (long i = 0; i < 50; i++) {
            *dst++ = *src++;
        }
    }
    
    /* test_multiple_postinc - multiple post-increment in same loop iteration
     * Optimizations:
     *   - Post-increment addressing: All 4 move.l use (%a0)+,(%a1)+ addressing
     *   - Loop counter optimization: Uses subq.l #1,%d0 + jne instead of addq + cmp
     * Observed: Saves 4 instructions by using (aX)+ for all accesses instead of
     *   indexed addressing (4(%a0), 8(%a0), etc.) plus lea for pointer adjustment.
     * Responsible: m68k_reorg_postinc() for auto-increment conversion
     * Savings at -O2: ~54 cycles/iteration (4x indexed=112 + 2x lea=16 vs
     *   4x postinc=80), 16 bytes static (indexed 6 bytes vs postinc 2 bytes each)
     * Savings at -Os: ~54 cycles/iteration (same pattern), 16 bytes static
     */
    void test_multiple_postinc(const int* src, int* dst, unsigned int count) {
        for (unsigned int i = 0; i < count / 4; i++) {
            *dst++ = *src++;
            *dst++ = *src++;
            *dst++ = *src++;
            *dst++ = *src++;
        }
    }
    
    /* test_multiple_postinc_short - tests negative offset relocation optimization
     * Problem: IVOPTS places increment in middle of access sequence, causing
     *   some accesses to use negative offsets (e.g., move.w -2(%a0),-2(%a1))
     *   which cannot be converted to POST_INC addressing.
     * Responsible: m68k_pass_opt_autoinc Phase 1 (try_relocate_increment)
     * Savings: ~32 cycles/iteration, 12 bytes static
     */
    void test_multiple_postinc_short(const short* src, short* dst, unsigned int count) {
        for (unsigned int i = 0; i < count / 4; i++) {
            *dst++ = *src++;
            *dst++ = *src++;
            *dst++ = *src++;
            *dst++ = *src++;
        }
    }
    
    /* test_unrolled_postinc - compiler-unrolled loop with post-increment
     * Optimizations:
     *   - Post-increment addressing: move.w (%a0)+,(%a1)+ for memory access
     *   - Loop counter optimization: Uses subq.l/jne countdown pattern
     * Observed: Pragma unroll not effective; single move.w (%a0)+,(%a1)+
     *   per iteration with efficient countdown loop control.
     * Responsible: m68k_reorg_postinc()
     * Savings at -O2: ~6 cycles/iteration (addq + cmp vs subq), 2 bytes static
     * Savings at -Os: ~14 cycles/iteration (indexed move.w d(an),d(an)=24 + add=8
     *   vs postinc move.w (an)+,(an)+=12 + addq=8), 4 bytes static
     */
    void test_unrolled_postinc(const short* src, short* dst, unsigned int count) {
#pragma unroll 4
        for (unsigned int i = 0; i < count; i++) {
            *dst++ = *src++;
        }
    }
    
    /* test_postinc_write - post-increment on write operation
     * Optimizations:
     *   - Post-increment on store: move.w %d0,(%a2)+ instead of move.w %d0,-2(%a2)
     *   - Read without post-increment: move.w (%a2),%d0 preserves pointer for write
     * Observed: Saves 1 instruction; post-increment applied to write not read,
     *   avoiding negative offset addressing after premature increment.
     * Responsible: m68k_reorg_postinc() write-preferring heuristics
     * Savings at -O2: ~10 cycles/iteration (move.w d(an)=12 + addq=8 + cmp=6 vs
     *   move.w (an)+=8 + subq=8), 4 bytes static
     * Savings at -Os: ~10 cycles/iteration (similar pattern), 4 bytes static
     */
    void test_postinc_write(short *dst, unsigned int count, int (*p)(short)) {
        for (unsigned int i = 0; i < count; i++) {
            dst[i] = p(dst[i]) ? i : 0;
        }
    }
    
    /* test_array_to_postinc - array indexing converted to post-increment
     * Optimizations:
     *   - Array to post-increment: dst[i] becomes (%a0)+ addressing
     *   - Loop counter optimization: subq.l/jne countdown pattern
     * Observed: Array syntax dst[i]=i converted to move.w %d2,(%a0)+ with
     *   efficient loop control instead of indexed addressing.
     * Responsible: m68k_reorg_postinc() array access pattern recognition
     * Savings at -O2: ~6 cycles/iteration (addq + cmp vs subq), 2 bytes static
     * Savings at -Os: ~8 cycles/iteration (indexed addressing eliminated), 4 bytes
     */
    void test_array_to_postinc(short *dst, unsigned int count) {
        for (unsigned int i = 0; i < count; i++) {
            dst[i] = i;
        }
    }
    
    /* test_while_postinc - post-increment in while loop
     * Optimizations:
     *   - Post-increment addressing: move.b (%a0)+,%d0 and move.b %d0,(%a1)+
     * Observed: At -O2 identical output; at -Os converts indexed to post-increment.
     * Responsible: GCC RTL generation at -O2, m68k_reorg_postinc() at -Os
     * Savings at -O2: 0 cycles, 0 bytes (already optimal)
     * Savings at -Os: ~12 cycles/iteration (indexed move.b d(an)=12 + addq=8 vs
     *   postinc move.b (an)+=8), 6 bytes static (eliminates counter and indexed addr)
     */
    void test_while_postinc(const char *src, char* dst) {
        while ((*dst++ = *src++) != '\0');
    }
    
    /* test_while_postinc_bounded - post-increment with dual exit conditions
     * Optimizations:
     *   - Post-increment addressing: move.b (%a2)+,%d1 and move.b %d1,(%a1)+
     * Observed: At -O2 identical output; at -Os uses postinc but adds register saves.
     * Responsible: GCC RTL generation at -O2, m68k_reorg_postinc() at -Os
     * Savings at -O2: 0 cycles, 0 bytes (already optimal)
     * Savings at -Os: ~8 cycles/iteration (indexed=24 vs postinc=16), but adds
     *   ~44 cycles overhead for register save/restore; net win for strings > 6 chars
     */
    void test_while_postinc_bounded(const char *src, char* dst, int count) {
        while (--count >= 0 && (*dst++ = *src++) != '\0')
            continue;
    }
    
    /* test_matrix_add - nested loops with index calculation
     * Optimizations:
     *   - Loop to dbra conversion: Both inner and outer loops use dbra
     *   - Register save optimization: Single movem.l instead of multiple push/pop
     *   - Post-increment addressing: move.l %d2,(%a1)+ in inner loop
     * Observed: Saves 6 instructions; uses movem.l %d3-%d5 instead of separate
     *   moves, and dbra for both loop levels instead of cmp/jne.
     * Responsible: m68k_reorg() doloop handling, GCC register allocation
     * Savings at -O2: ~12 cycles/inner iteration (cmp + jne vs dbra), ~6 cycles/
     *   outer iteration; 12 bytes static (movem vs separate moves, dbra vs cmp/jne)
     * Savings at -Os: ~6 cycles/inner iteration (dbra vs cmp/jne), 8 bytes static
     */
    void test_matrix_add(int *m, unsigned short n, int a) {
        if (n > 255) __builtin_unreachable();
        for (unsigned short i = 0; i < n; i++) {
            for (unsigned short j = 0; j < n; j++) {
                m[i * n + j] += a;
            }
        }
    }
    
    /* test_matrix_mul - matrix-vector multiply with nested loops
     * Optimizations:
     *   - Loop to dbra conversion: Both loops use dbra instruction
     *   - Post-increment addressing: (%a0)+ and (%a1)+ in inner loop
     * Observed: Inner loop uses dbra with muls.w (%a1)+,%d2 combining
     *   multiply with auto-increment addressing for efficiency.
     * Responsible: m68k_reorg() doloop handling, m68k_reorg_postinc()
     * Savings at -O2: ~6 cycles/inner iteration (cmp + jne vs dbra), 8 bytes static
     * Savings at -Os: ~6 cycles/inner iteration (dbra vs cmp/jne), 6 bytes static
     */
    void test_matrix_mul(short *a, short *b, short *r, unsigned short n) {
        for (unsigned short i = 0; i < n; i++) {
            r[i] = 0;
            for (unsigned short j = 0; j < n; j++) {
                r[i] += a[i * n + j] * b[j];
            }
        }
    }
    
    /* test_redundant_move - redundant move elimination
     * Optimizations:
     *   - Loop counter optimization: subq.l/jne countdown eliminates cmp instruction
     *   - Dead code elimination: Single exit point instead of duplicate return
     * Observed: Saves 3 instructions; countdown loop with subq.l #1,%d1 + jne
     *   replaces addq.l + cmp.l + jne, and eliminates duplicate moveq #0 return.
     * Responsible: GCC RTL optimization passes, m68k_reorg_redundant_moves()
     * Savings at -O2: ~6 cycles/iteration (addq + cmp vs subq), ~20 cycles static
     *   (eliminates duplicate return path), 6 bytes static
     * Savings at -Os: 0 cycles, 0 bytes (similar structure in both)
     */
    long test_redundant_move(long *ptr, long count) {
        long sum = 0;
        long *p = ptr;
        for (long i = 0; i < count; i++) {
            sum += *p++;
        }
        return sum;
    }
    
    /* test_loop_moves - loop move propagation for d<->a transfers
     * Optimizations:
     *   - Post-increment addressing: add.l (%a0)+,%d0 in loop body
     *   - Loop counter optimization: subq.l/jne countdown pattern
     * Observed: Saves 4 instructions; pointer kept in address register throughout
     *   loop with (a0)+ access, avoiding repeated d->a transfers.
     * Responsible: GCC RTL optimization, m68k_reorg_loop_moves()
     * Savings at -O2: ~22 cycles/iteration (3x add.l for pointer calc + cmp vs
     *   subq), ~20 cycles static (eliminates duplicate return), 8 bytes static
     * Savings at -Os: 0 cycles, 0 bytes (similar structure in both)
     */
    long test_loop_moves(long *data, int count) {
        long ptr_as_long = (long)data;
        long sum = 0;
        for (int i = 0; i < count; i++) {
            long *p = (long *)ptr_as_long;
            sum += p[i];
        }
        return sum;
    }
    
    /* test_stack_slots - stack slot optimization
     * Optimizations:
     *   - Register allocation: All temporaries kept in registers, no stack spills
     * Observed: Identical output (4 add.l instructions + rts) at all optimization
     *   levels; simple enough that GCC keeps everything in d0/d1/d2.
     * Responsible: GCC register allocator (IRA/LRA)
     * Savings at -O2: 0 cycles, 0 bytes (GCC already optimizes)
     * Savings at -Os: 0 cycles, 0 bytes (GCC already optimizes)
     */
    int test_stack_slots(int a, int b, int c) {
        int temp1 = a + b;
        int temp2 = b + c;
        int temp3 = temp1;  /* Should use register, not reload from stack */
        return temp1 + temp2 + temp3;
    }
    
    // Copy function, simulate std::copy
    __attribute__((__always_inline__)) inline
    short *copy(const short *first, const short *last, short *d_first) {
        while (first != last) {
            *(d_first) = *(first);
            ++d_first; ++first;
        }
        return d_first;
    }
    
    // Copy count function.
    __attribute__((__always_inline__, optimize("unroll-loops"))) inline
    short *copyn(const short *first, unsigned short count, short *d_first) {
        #pragma GCC unroll 8
        while (count--) {
            *(d_first) = *(first);
            ++d_first; ++first;
        }
        return d_first;
    }
    
    
    void test_copy_16(const short *src, short *dst) {
        copy(src, src + 16, dst);
    }
    void test_copy(const short *beg, const short *end, short *dst) {
        copy(beg, end, dst);
    }
    void test_copyn_16(const short *src, short *dst) {
        copyn(src, 16, dst);
    }
    void test_copyn(const short *src, short *dst, short count) {
        copyn(src, count, dst);
    }
    void test_copy_palette_16(const short *src) {
        copyn(src, 16, (short*)0xffff8240);
    }

    /* test_doloop_const_small - doloop with known small constant count
     * Expected: Should use dbra via DOLOOP infrastructure.
     * The DOLOOP pass should recognize the constant iteration count (100)
     * fits in 16 bits and generate doloop_end_hi pattern.
     */
    void test_doloop_const_small(short *p) {
        for (int i = 0; i < 100; i++) {
            p[i] = 0;
        }
    }
    
    /* test_doloop_himode - doloop with HImode (unsigned short) counter
     * Expected: Should use dbra via DOLOOP infrastructure when bound is known.
     * The unsigned short counter is naturally 16-bit, fitting dbra's semantics.
     */
    void test_doloop_himode(short *p, unsigned short n) {
        if (n > 1000) __builtin_unreachable();  /* Bound the iteration count */
        for (unsigned short i = 0; i < n; i++) {
            p[i] = 0;
        }
    }
    
    /* test_doloop_simode_unbounded - doloop with unbounded SImode counter
     * Expected: Should NOT use dbra because iteration count could exceed 65536.
     * The DOLOOP pass should reject this due to unknown maximum.
     */
    void test_doloop_simode_unbounded(int *p, unsigned int n) {
        for (unsigned int i = 0; i < n; i++) {
            p[i] = 0;
        }
    }
    
    /* test_doloop_const_large - doloop with large constant count (>65536)
     * Expected: Should NOT use dbra because count exceeds 16-bit limit.
     * The DOLOOP pass should reject this due to iterations > 65536.
     */
    void test_doloop_const_large(char *p) {
        for (int i = 0; i < 100000; i++) {
            p[i] = 0;
        }
    }
    
    int test_clear_buffer(int(*f)(int*), short i) {
        int buf_a[8] = {0};
        int buf_b[8] = {-7,-2,-7,-2,-7,-2,-7,-2};
        buf_a[i] = 1;
        buf_b[i] = 1;
        return f(buf_a) + f(buf_b);
    }
    
    /* ==========================================================================
     * CLR OPTIMIZATION TEST CASES
     *
     * On the MC68000, the CLR instruction performs a read-modify-write cycle
     * when the destination is memory.  This causes:
     *   1. Performance penalty (extra bus cycle for unnecessary read)
     *   2. Hardware issues with memory-mapped I/O (read side-effects)
     *
     * The opt_clear pass converts groups of clr-to-memory instructions to use
     * a zero register when total bytes cleared >= 4.
     * ========================================================================== */
    
    /* test_clear_single_long - single clear to memory
     * Expected for 68000: Should use moveq + move.l (saves 4 cycles)
     * Expected for 68020+: Should use clr.l (no CLR bug)
     * The single clr.l clears 4 bytes, meeting the threshold.
     */
    void test_clear_single_long(int *p) {
        *p = 0;
    }
    
    /* test_clear_single_word - single word clear to memory
     * Expected for 68000: Should KEEP clr.w (only 2 bytes, below threshold)
     * Expected for 68020+: Should use clr.w
     * The moveq overhead is not amortized for just 2 bytes.
     */
    void test_clear_single_word(short *p) {
        *p = 0;
    }
    
    /* test_clear_two_longs - two long clears to memory
     * Expected for 68000: moveq #0,dx; move.l dx,(a0); move.l dx,4(a0)
     * Expected for 68020+: clr.l (a0); clr.l 4(a0)
     * Two clr.l = 8 bytes cleared, well above threshold.
     * Savings: 2 bytes smaller, ~20 cycles faster on 68000.
     */
    void test_clear_two_longs(int *p) {
        p[0] = 0;
        p[1] = 0;
    }
    
    /* test_clear_struct - clear multiple struct fields
     * Expected for 68000: Single moveq, multiple move.l
     * Expected for 68020+: Multiple clr.l
     * Tests that clears to different offsets share the zero register.
     */
    struct quad { int a, b, c, d; };
    void test_clear_struct(struct quad *s) {
        s->a = 0;
        s->b = 0;
        s->c = 0;
        s->d = 0;
    }

    /* test_clear_struct - clear multiple struct fields
     * Expected for 68000: Single moveq, multiple move.l
     * Expected for 68020+: Multiple clr.l
     * Tests that clears to different offsets share the zero register.
     */
    void test_clear_struct_unorderred(struct quad *s) {
        s->d = 0;
        s->b = 0;
        s->c = 0;
        s->a = 0;
    }

    /* test_clear_array_loop - array clearing loop
     * Expected for 68000: moveq hoisted, move.l in loop
     * Expected for 68020+: clr.l in loop
     * This is the most important case - loop iterations benefit hugely.
     */
    void test_clear_array_loop(int *p, int n) {
        while (n--) *p++ = 0;
    }
    
    /* test_clear_mixed_sizes - mixed size clears
     * Expected: Should optimize if total >= 4 bytes
     * Two words (4 bytes) + one long (4 bytes) = 8 bytes total.
     */
    void test_clear_mixed_sizes(char *p) {
        *(short *)p = 0;
        *(short *)(p + 2) = 0;
        *(int *)(p + 4) = 0;
    }
    
    /* Array lookup by int
     */
    short test_array_indexing(short* arr, int i) {
        return arr[i];
    }
    
    /* Array lookup by byte
     */
    short test_array_indexing_byte(short* arr, char i) {
        return arr[i];
    }
    
    /* Array lookup by int, with assume compiler hint for range
     */
    short test_array_indexing_assume(short* arr, int i) {
        __attribute__((assume(i >= 0 && i < (0x8000 / sizeof(short)))));
        return arr[i];
    }
    
    /* Array lookup by int, with sized array
     */
    short test_array_indexing_sized(short arr[100], int i) {
        return arr[i];
    }
    
    /* Array lookup by byte
     */
    char test_byte_array_indexing(char* arr, int i) {
        return arr[i];
    }
    short test_vector(vector_c<short> &vec, int i) {
        return vec[i];
    }

    short test_vector_back(vector_c<short> &vec) {
        return vec.back();
    }

    short test_vector_emplace_back(vector_c<short> &vec, short a) {
        return vec.emplace_back(a);
    }

    /* ==========================================================================
     * ANDI.L #65535 ELIMINATION TEST CASES
     *
     * On M68K, word (.w) operations only modify the lower 16 bits, leaving
     * upper bits unchanged.  GCC often generates andi.l #65535 to zero-extend
     * for 32-bit address calculations.  By pre-clearing the register with
     * moveq #0, we can eliminate the expensive andi.l instruction.
     *
     * Savings per elimination:
     *   68000/68010: 4 bytes, 8-16 cycles
     *   68020+: 4 bytes, ~4 cycles
     * ========================================================================== */

    /* test_elim_andi_basic - basic andi elimination
     * Expected: moveq #0 inserted before move.w, andi eliminated.
     * Pattern: Load word, decrement, use as index.
     */
    unsigned short test_elim_andi_basic(unsigned short *p, unsigned short i) {
        unsigned short val = p[i];
        val--;
        return p[val];
    }

    /* test_elim_andi_multi - multiple word operations
     * Expected: moveq #0 inserted, all andi eliminated.
     * Pattern: Load word, add, shift, mask, use as index.
     */
    unsigned short test_elim_andi_multi(unsigned short *p, unsigned short i) {
        i += 10;
        i = i << 1;    /* Becomes add.w %d0,%d0 */
        i &= 0x1ff;    /* and.w - preserves upper bits */
        return p[i];
    }

    /* test_elim_andi_loop - andi in loop body
     * Expected: moveq #0 hoisted before definition, saves andi per iteration.
     * This is the highest-value case.
     */
    unsigned int test_elim_andi_loop(unsigned short *p, unsigned short n) {
        unsigned int sum = 0;
        for (unsigned short i = 0; i < n; i++) {
            unsigned short val = p[i];
            val &= 0xff;     /* word operation */
            sum += val;      /* uses val as 32-bit - would need andi */
        }
        return sum;
    }

    /* test_no_elim_muls - should NOT optimize (muls produces 32-bit result)
     * Expected: No optimization, muls clobbers upper bits with meaningful data.
     */
    int test_no_elim_muls(short a, short b) {
        return a * b;  /* muls produces 32-bit result */
    }

    /* test_no_elim_ext - should NOT optimize (ext.l sets upper bits)
     * Expected: No optimization, ext.l sign-extends (sets upper bits).
     */
    int test_no_elim_ext(short val) {
        return (int)val;  /* ext.l sign-extends */
    }

    /* test_elim_andi_zext - zero_extend is safe
     * Expected: Should optimize - zero_extend clears upper bits like moveq #0.
     */
    unsigned int test_elim_andi_zext(unsigned short val) {
        unsigned int x = val;  /* zero_extend clears upper 16 bits */
        x += 1;
        return x;
    }

    /* test_elim_andi_load - load from memory then use as 32-bit
     * Expected: moveq #0 inserted before load, andi eliminated.
     * Pattern: Load word from memory (pure definition), add, return as 32-bit.
     */
    unsigned int test_elim_andi_load(unsigned short *p) {
        unsigned short val = *p;   /* move.w (%a0),%d0 - pure load */
        val += 5;                  /* addq.w #5,%d0 - word op */
        return val;                /* needs 32-bit result */
    }

    /* test_elim_andi_load2 - two independent loads
     * Expected: Both should use moveq #0 + word ops.
     */
    unsigned int test_elim_andi_load2(unsigned short *p, unsigned short *q) {
        unsigned short a = *p;
        unsigned short b = *q;
        a += 10;
        b += 20;
        return a + b;
    }

    /* ==========================================================================
     * BYTE EXTENSION ELIMINATION TEST CASES
     *
     * Similar to word extension, but for andi.l #255 / andi.w #255.
     * By pre-clearing the register, we can eliminate the expensive andi.
     *
     * Savings per elimination:
     *   68000/68010: 4-6 bytes, 8-16 cycles
     *   68020+: 4-6 bytes, ~4 cycles
     * ========================================================================== */

    /* test_elim_andi_byte_load - load byte then use as 32-bit
     * Expected: moveq #0 inserted before move.b, andi.l #255 eliminated.
     */
    unsigned int test_elim_andi_byte_load(unsigned char *p) {
        unsigned char val = *p;   /* move.b (%a0),%d0 - pure load */
        val += 5;                 /* addq.b #5,%d0 - byte op */
        return val;               /* needs 32-bit result */
    }

    /* test_elim_andi_byte_multi - multiple byte operations
     * Expected: moveq #0 inserted, andi eliminated.
     */
    unsigned int test_elim_andi_byte_multi(unsigned char *p) {
        unsigned char val = *p;
        val += 10;
        val &= 0x7f;              /* and.b - preserves upper bits */
        return val;
    }

    /* test_elim_andi_byte_loop - byte extension in loop
     * Expected: moveq #0 hoisted, saves andi per iteration.
     */
    unsigned int test_elim_andi_byte_loop(unsigned char *p, unsigned short n) {
        unsigned int sum = 0;
        for (unsigned short i = 0; i < n; i++) {
            unsigned char val = p[i];
            val &= 0x0f;          /* and.b - byte operation */
            sum += val;           /* uses val as 32-bit */
        }
        return sum;
    }

    /* test_no_elim_byte_word_op - should NOT optimize
     * Expected: No optimization because word op clobbers bits 8-15.
     */
    unsigned int test_no_elim_byte_word_op(unsigned char val) {
        unsigned short x = val;   /* zero-extend to word first */
        x += 256;                 /* word op - modifies bit 8 */
        return x;
    }

    /* test_elim_andi_byte_to_word - andi.w #255 elimination
     * Expected: clr.w or moveq inserted, andi.w #255 eliminated.
     */
    unsigned short test_elim_andi_byte_to_word(unsigned char *p) {
        unsigned char val = *p;
        val += 1;
        return val;               /* needs 16-bit result */
    }

    /* test_elim_andi_byte_index - byte used as array index
     * Expected: moveq #0 inserted, andi eliminated.
     */
    int test_elim_andi_byte_index(int *arr, unsigned char idx) {
        idx += 1;
        return arr[idx];
    }

    /* ==========================================================================
     * CROSS-BASIC-BLOCK TEST CASES
     *
     * Test the cross-basic-block optimization where the definition
     * is in a predecessor block.
     * ========================================================================== */

    /* test_cross_bb_simple - definition in if-then block
     * Expected: Optimization should work across the conditional.
     */
    unsigned int test_cross_bb_simple(unsigned short *p, int cond) {
        unsigned short val;
        if (cond)
            val = p[0];
        else
            val = p[1];
        return val;  /* andi needed - should try cross-bb optimization */
    }

    /* test_cross_bb_simple - definition in if-then block
     * Expected: Optimization should work across the conditional.
     */
    unsigned int test_cross_bb_cond(unsigned short *a, unsigned short *b, unsigned short i, bool cond) {
        unsigned int res;
        if (cond)
            res = a[i];
        else
            res = b[i];
        return res;  /* andi needed - should try cross-bb optimization */
    }

    /* test_cross_bb_loop - definition before loop
     * Expected: moveq before definition, andi in loop eliminated.
     */
    unsigned int test_cross_bb_loop(unsigned short start, unsigned short n) {
        unsigned short val = start;
        for (unsigned short i = 0; i < n; i++) {
            val += i;
        }
        return val;
    }

    struct point_t {
        short x, y;
    };
    void test_small_struct(short(*f)(point_t)) {
        for (int y = 0; y < 4; y++) {
            for (int x = 0; x < 4; x++) {
                (void)f({x * 2, y});
            }
        }
    }

    /* ==========================================================================
     * HIGH-WORD FIELD ACCESS OPTIMIZATION TEST CASES
     *
     * When small structs (4 bytes) are passed by value in registers, accessing
     * the high 16 bits generates suboptimal code.  The m68k_pass_highword_opt
     * pass optimizes these patterns:
     *
     * Extraction:  clr.w %d0; swap %d0  ->  swap %d0
     * Computation: swap %d0; ext.l %d0; add.w  ->  swap %d0; add.w
     * Insertion:   swap; clr.w; and.l #65535; or.l  ->  swap; move.w; swap
     *
     * Tests compiled with -mfastcall: struct s4 passed in d0 (a:high, b:low).
     * ========================================================================== */

    /* Small struct for by-value passing tests.
     * With -mfastcall, this fits in d0 (s.a in high word, s.b in low word).
     */
    struct s4 { short a, b; };

    /* test_highword_extract_low - Case 1: extract low word (OPTIMAL)
     * Current:  rts  (0 insns, value already in low word)
     * This is the baseline - already optimal.
     */
    short test_highword_extract_low(struct s4 s) {
        return s.b;  /* b is at offset 2 (low word) */
    }

    /* test_highword_extract_high - Case 2: extract high word (SUBOPTIMAL)
     * Current:  clr.w %d0; swap %d0  (2 insns)
     * Optimal:  swap %d0             (1 insn)
     * Savings: 1 instruction, ~4 cycles
     */
    short test_highword_extract_high(struct s4 s) {
        return s.a;  /* a is at offset 0 (high word) */
    }

    /* test_highword_extract_computed - Case 3: extract high + compute (SUBOPTIMAL)
     * Current:  swap %d0; ext.l %d0; add.w %d1,%d0  (3 insns)
     * Optimal:  swap %d0; add.w %d1,%d0             (2 insns)
     * The ext.l is unnecessary since signed overflow is UB.
     * Savings: 1 instruction, ~4 cycles
     */
    short test_highword_extract_computed(struct s4 s, short x) {
        return s.a + x;
    }

    /* test_highword_insert_low - Case 4: insert to low word (OPTIMAL)
     * Current:  move.w %d1,%d0  (1 insn, strict_low_part)
     * This is the baseline - already optimal.
     */
    struct s4 test_highword_insert_low(struct s4 s, short v) {
        s.b = v;
        return s;
    }

    /* test_highword_insert_high - Case 5: insert to high word (SUBOPTIMAL)
     * Current:  swap %d1; clr.w %d1; and.l #65535,%d0; or.l %d1,%d0  (4 insns)
     * Optimal:  swap %d0; move.w %d1,%d0; swap %d0                   (3 insns)
     * Savings: 1 instruction, ~8 cycles
     */
    struct s4 test_highword_insert_high(struct s4 s, short v) {
        s.a = v;
        return s;
    }

    /* test_highword_insert_computed - Case 6: insert computed to high (SUBOPTIMAL)
     * Current:  add.w %d1,%d2; swap %d2; clr.w %d2; and.l #65535,%d0; or.l %d2,%d0  (5 insns)
     * Optimal:  add.w %d1,%d2; swap %d0; move.w %d2,%d0; swap %d0                   (4 insns)
     * Savings: 1 instruction, ~8 cycles
     */
    struct s4 test_highword_insert_computed(struct s4 s, short x, short y) {
        s.a = x + y;
        return s;
    }

    struct bit_struct_s {
        unsigned char id;
        unsigned char active: 1;
        unsigned char event: 1;
        unsigned char flag: 5;
        unsigned char hidden: 1;
        short data;
    };
    static_assert(sizeof(bit_struct_s) == 4);
    unsigned char test_bit_struct_active(struct bit_struct_s &s, int op) {
        switch (op) {
            case 10:
                s.active = 0;
                break;
            case 11:
                s.active = 1;
                break;
            case 12:
                s.active ^= 1;
                break;
            case 13:
                s.active = ~s.active;
                break;
            case 14:
                s.active = !s.active;
                break;
            case 15:
                return s.active;
            default:
                if (s.active) {
                    return 42;
                } else {
                    return 12;
                }
        }
        return 0;
    }

    unsigned char test_bit_struct_event(struct bit_struct_s &s, int op) {
        switch (op) {
            case 10:
                s.event = 0;
                break;
            case 11:
                s.event = 1;
                break;
            case 12:
                s.event ^= 1;
                break;
            case 13:
                s.event = ~s.event;
                break;
            case 14:
                s.event = !s.event;
                break;
            case 15:
                return s.event;
            default:
                if (s.event) {
                    return 42;
                } else {
                    return 12;
                }
        }
        return 0;
    }
    
    unsigned char test_bit_struct_flag(struct bit_struct_s &s, int op) {
        switch (op) {
            case 10:
                s.flag = 0;
                break;
            case 11:
                s.flag = 1;
                break;
            case 12:
                s.flag ^= 1;
                break;
            case 13:
                s.flag = ~s.flag;
                break;
            case 14:
                s.flag = !s.flag;
                break;
            case 15:
                return s.flag;
            default:
                if (s.flag) {
                    return 42;
                } else {
                    return 12;
                }
        }
        return 0;
    }

    unsigned char test_bit_struct_hidden(struct bit_struct_s &s, int op) {
        switch (op) {
            case 10:
                s.hidden = 0;
                break;
            case 11:
                s.hidden = 1;
                break;
            case 12:
                s.hidden ^= 1;
                break;
            case 13:
                s.hidden = ~s.hidden;
                break;
            case 14:
                s.hidden = !s.hidden;
                break;
            case 15:
                return s.hidden;
            default:
                if (s.hidden) {
                    return 42;
                } else {
                    return 12;
                }
        }
        return 0;
    }
    
    /* ==========================================================================
     * BTST+SNE SINGLE-BIT EXTRACTION TEST CASES
     *
     * On 68000/68010, (x >> N) & 1 uses lsr+and which costs 10+2N to 16+2N
     * cycles.  btst tests any bit in one instruction, and combined with sne
     * produces a fixed-cost result regardless of bit position.
     *
     * sne produces 0xFF (-1) or 0x00 — STORE_FLAG_VALUE = -1.
     * Unsigned extraction (0 or 1): btst + sne + neg.b
     * Signed extraction (0 or -1): btst + sne only
     * ========================================================================== */

    struct byte_fields { unsigned char a : 1, b : 1, c : 1, d : 1, e : 1; };
    struct signed_byte_fields { signed char a : 1, b : 1, c : 1, d : 1, e : 1; };

    /* test_extract_mem_unsigned - QI memory unsigned, bit 4
     * Expected for 68000: btst #3,(a0); sne d0; neg.b d0 (3 insns)
     * Expected for 68020+: bfextu (a0){#4:#1},d0 (1 insn)
     * Savings on 68000: 2N cycles (N=4 -> 8 cycles)
     */
    unsigned char test_extract_mem_unsigned(struct byte_fields *p) { return p->e; }

    /* test_extract_mem_signed - QI memory signed, bit 4
     * Expected for 68000: btst #3,(a0); sne d0 (2 insns, no neg!)
     * Expected for 68020+: bfexts (a0){#4:#1},d0
     * Savings on 68000: 20+2K cycles (K=4 -> 28 cycles)
     */
    signed char test_extract_mem_signed(struct signed_byte_fields *p) { return p->e; }

    /* test_extract_reg_bit6 - QI register unsigned, bit 6 (>= 4)
     * Expected for 68000: btst #6,d0; sne d0; neg.b d0 (transformed)
     * Expected for 68020+: lsr.b #6,d0; and.b #1,d0 (not transformed)
     * Savings on 68000: 2N-6 cycles (N=6 -> 6 cycles)
     */
    unsigned char test_extract_reg_bit6(unsigned char x) { return (x >> 6) & 1; }

    /* test_extract_reg_bit1 - QI register unsigned, bit 1 (< 4)
     * Expected for 68000: lsr.b #1,d0; and.b #1,d0 (NOT transformed)
     * Threshold is N>=4 for register, so bit 1 is not profitable.
     */
    unsigned char test_extract_reg_bit1(unsigned char x) { return (x >> 1) & 1; }

    /* test_unroll_tablejump - Runtime loop unroll with tablejump dispatch.
     * The loop body (p[i] = i) prevents memset/memclr optimization.
     * Expected: tablejump (jmp pc@(2,dN:w)) + .word offset table,
     *   instead of a serial compare cascade (7 cmp+beq pairs).
     * This tests the TARGET_PREFER_RUNTIME_UNROLL_TABLEJUMP hook.
     */
    __attribute__((noinline))
    void test_unroll_tablejump(int *p, int n, int(*f)(int)) {
        #pragma GCC unroll 4
        for (int i = 0; i < n; i++)
            p[i] = i;
    }

    /* test_unroll_tablejump_ref - Manual Duff's device as reference.
     * This is what the compiler's runtime unroller should produce
     * (structurally), with a tablejump for the switch.
     */
    __attribute__((noinline))
    void test_unroll_tablejump_manual(int *p, int n, int(*f)(int)) {
        int i = 0;
        int mod = n & 3;
        switch (mod) {
            case 3: p[i] = f(i); i++;  [[fallthrough]];
            case 2: p[i] = f(i); i++;  [[fallthrough]];
            case 1: p[i] = f(i); i++;  [[fallthrough]];
            case 0: break;
        }
        while (i < n) {
            p[i] = f(i); i++;
            p[i] = f(i); i++;
            p[i] = f(i); i++;
            p[i] = f(i); i++;
        }
    }

    /* test_null_ptr_loop - linked list traversal with NULL pointer check
     * Optimizations:
     *   - Address register zero test: On 68000/68010, the NULL check
     *     (while (p)) generates cmp.w #0,%aN (4 bytes, 12 cycles) because
     *     tst.l doesn't work on address registers.  Peephole2 replaces
     *     with move.l %aN,%dN (2 bytes, 4 cycles) + CC elision.
     * Expected for 68000: move.l %aN,%dN + jCC instead of cmp.w #0,%aN + jCC
     * Expected for 68020+: tst.l %aN (already optimal, no transformation)
     * Responsible: peephole2 (address register zero test), CC elision
     * Savings at -O2 (68000): 2 bytes, ~8 cycles per NULL check
     */
    struct node { struct node *next; int val; };
    int __attribute__((noinline)) test_null_ptr_loop(struct node *p) {
        int sum = 0;
        while (p) {
            sum += p->val;
            p = p->next;
        }
        return sum;
    }

    /* test_btst_ashiftrt_hi - HI-mode btst extraction with arithmetic shift
     * Signed type forces ashiftrt; shift by 9 exceeds 68000 immediate limit
     * (1-8), requiring a register load — tests 3-insn peephole (Pattern F).
     * Expected for 68000: btst #9,d0; sne d0; neg.b d0
     * Savings: ~16 cycles (moveq+asr+and=36 vs btst+sne+neg=20)
     */
    short __attribute__((noinline)) test_btst_ashiftrt_hi(short val) {
        return (val >> 9) & 1;
    }

    /* test_btst_ashiftrt_hi_const - HI-mode btst extraction with const shift
     * Shift by 5 is within 68000 immediate range (1-8) — tests 2-insn
     * peephole (Pattern E).
     * Expected for 68000: btst #5,d0; sne d0; neg.b d0
     * Savings: ~8 cycles (asr+and=28 vs btst+sne+neg=20)
     */
    short __attribute__((noinline)) test_btst_ashiftrt_hi_const(short val) {
        return (val >> 5) & 1;
    }

    /* ==========================================================================
     * ANDI_ZEXT ENHANCEMENT TEST CASES (CRC table lookup patterns)
     *
     * These test the two gaps in the backward scan of the andi_zext pass:
     *
     * Pattern 1 (clr.w + move.b): The backward scan hits move.b (DEFINES_BYTE)
     * and stops, never reaching the clr.w (DEFINES_WORD) above it.  Fix:
     * continue past DEFINES_BYTE for WORD_TO_LONG, then widen clr.w to moveq.
     *
     * Pattern 2 (and.w #N): Function parameter has no definition in the BB.
     * and.w #255 masks to byte range but leaves bits 16-31 dirty.  Fix:
     * widen and.w #N to and.l #N to clear upper bits, eliminating later
     * and.l #65535.
     * ========================================================================== */

    /* test_andi_clrw_byte_def - clr.w + move.b pattern (Gap 1)
     * Uses cdecl to get stack parameters, which generates:
     *   clr.w %dN; move.b src,%dN; byte_ops; add.w; and.l #65535
     * The backward scan hits move.b (DEFINES_BYTE) and stops, never
     * reaching clr.w (DEFINES_WORD).  Fix: continue past DEFINES_BYTE
     * for WORD_TO_LONG, then widen clr.w to moveq #0.
     * Expected: no and.l #65535 in output (68000 targets).
     * Responsible: Pass 250b (m68k_pass_elim_andi)
     * Savings at -O2: 16 cycles, 6 bytes per elimination
     */
    extern unsigned short ext_table[256];
    unsigned short __attribute__((noinline, cdecl))
    test_andi_clrw_byte_def(unsigned char data, unsigned short crc) {
        unsigned char rev = data;
        rev = ((rev >> 4) | (rev << 4));
        rev = ((rev & 0xCC) >> 2) | ((rev & 0x33) << 2);
        rev = ((rev & 0xAA) >> 1) | ((rev & 0x55) << 1);
        unsigned short idx = (unsigned short)rev ^ (crc >> 8);
        idx += idx;
        return ext_table[idx];
    }

    /* test_andi_widen_mask - and.w #255 widening pattern (Gap 2)
     * With fastcall, byte parameter in d0 has no explicit definition.
     * Backward scan finds and.w #255 (MODIFIES_WORD) but reaches function
     * entry with no definition.  Fix: widen and.w #255 to and.l #255 to
     * clear bits 16-31, eliminating later and.l #65535.
     * Expected: and.l #255 instead of and.w #255, no and.l #65535.
     * Responsible: Pass 250b (m68k_pass_elim_andi)
     * Savings at -O2: 8 cycles, 4 bytes per elimination
     */
    unsigned short __attribute__((noinline))
    test_andi_widen_mask(unsigned char data, unsigned short crc) {
        unsigned char rev = ((data >> 4) | (data << 4));
        unsigned short idx = (unsigned short)(rev & 0xFF) ^ (crc >> 8);
        idx += idx;
        return ext_table[idx];
    }

    /* test_areg_zero_elide - redundant move.l aN,dN elision
     * When a preceding instruction (e.g., move.l aN,<mem>) already sets CC
     * for the address register, the move.l aN,dN inserted by peephole2 for
     * NULL pointer checks is redundant.
     * Expected for 68000: store sets CC, branch directly (no move.l aN,dN)
     * Responsible: *cbranchsi4_areg_zero CC check in m68k.md
     * Savings at -O2 (68000): 2 bytes, 4 cycles per elided move
     */
    struct ref_count { int count; };
    void __attribute__((noinline))
    test_areg_zero_elide(ref_count **dst, ref_count *cnt) {
        *dst = cnt;
        if (cnt)
            cnt->count++;
    }

    int test_mintlib_strcmp(const char *scan1, const char *scan2) {
        register unsigned char c1, c2;
        if (!scan1)
            return scan2 ? -1 : 0;
        if (!scan2) return 1;
        do {
            c1 = (unsigned char) *scan1++; c2 = (unsigned char) *scan2++;
        } while (c1 && c1 == c2);
        if (c1 == c2) return(0);
        else if (c1 == '\0') return(-1);
        else if (c2 == '\0') return(1);
        else return(c1 - c2);
    }
    
    int test_libcmini_strcmp(const char *scan1, const char *scan2) {
        unsigned char c1, c2;
        if (!scan1) return scan2 ? -1 : 0;
        if (!scan2) return 1;
        do {
            c1 = (unsigned char) *scan1++; c2 = (unsigned char) *scan2++;
        } while (c1 && c1 == c2);
        if (c1 == c2) return 0;
        if (c1 == '\0') return -1;
        if (c2 == '\0') return 1;
        return c1 - c2;
    }
    
    char *test_mintlib_strcpy(char *dst, const char *src) {
        register char *dscan = dst;
        register const char *sscan = src;
        if (!sscan) sscan = "";
        while ((*dscan++ = *sscan++) != '\0')
            continue;
        return(dst);
    }

    char *test_libcmini_strcpy(char *dst, const char *src)
    {
        char *ptr = dst;
        while ((*dst++ = *src++) != '\0') ;
        return ptr;
    }
    
    long test_mintlib_strlen(const char *scan) {
        register const char *start = scan+1;
        if (!scan) return 0;
        while (*scan++ != '\0')
            continue;
        return ((long)scan - (long)start);
    }
    
    long test_libcmini_strlen(const char *s){
        const char *start = s;
        while (*s++) ;
        return s - start - 1;
    }

    /* ==========================================================================
     * SYNTH_MULT REGRESSION TEST CASES
     *
     * GCC's synth_mult replaces multiply-by-constant with shift+add sequences.
     * With the rewritten cost model, multiply instructions appear expensive
     * relative to shifts/adds, causing aggressive open-coding even for
     * constants with many set bits (e.g., division-by-3 reciprocal 0xAAAB).
     *
     * These tests verify the generated code for representative constants:
     *   - Division reciprocals (0xAAAB, 0xCCCD) — worst bloat, 9+ set bits
     *   - Simple constants (*3, *12) — should always be open-coded
     *   - Complex constants (*138) — borderline cases
     * ========================================================================== */

    /* test_div3_byte - unsigned byte division by 3 via reciprocal multiply
     * C division by 3 becomes: mulu.w #0xAAAB (43691), then lsr.l #17.
     * On 68020+, stock GCC uses a single 4-byte mulu.w instruction.
     * synth_mult may replace this with 11+ instructions of shifts+adds.
     * Expected: mulu.w #0xAAAB (or at most a short shift+add sequence)
     */
    unsigned char __attribute__((noinline))
    test_div3_byte(unsigned char x) {
        return x / 3;
    }

    /* test_div5_byte - unsigned byte division by 5 via reciprocal multiply
     * C division by 5 becomes: mulu.w #0xCCCD (52429), then lsr.l #18.
     * Same concern as div3: 0xCCCD has 10 set bits → severe open-coding.
     * Expected: mulu.w #0xCCCD (or at most a short shift+add sequence)
     */
    unsigned char __attribute__((noinline))
    test_div5_byte(unsigned char x) {
        return x / 5;
    }

    /* test_clr_struct_arg - struct zero arg must clear all 32 bits
     * Regression test for miscompilation where andi.l #$ffff + clr.w
     * was incorrectly reduced to just clr.w, leaving garbage in the
     * high word of a 4-byte struct passed by register.
     *
     * The struct point_s{short x, short y} is 4 bytes (SImode).
     * point_s{0,0} must produce a full 32-bit zero (moveq #0 or clr.l),
     * not just clr.w which only clears the low 16 bits.
     */
    struct point_s { short x, y; };

    extern void __attribute__((noinline))
    use_point(void* canvas, void* image, void* rect, point_s p);

    extern void* __attribute__((noinline)) alloc_obj();
    extern short __attribute__((noinline)) get_count(void* obj);
    extern void __attribute__((noinline))
    draw_tile(void* canvas, void* tile, short idx, point_s at, int color);

    void __attribute__((noinline))
    test_clr_struct_arg(void* data, void* tiles, void* rect, short n) {
        for (short i = 0; i < n; ++i) {
            void* obj = alloc_obj();
            use_point(obj, data, rect, point_s{0, 0});
            short count = get_count(tiles);
            for (short j = 0; j < count; ++j) {
                draw_tile(obj, tiles, j, point_s{(short)j, (short)i}, -1);
            }
        }
    }

}

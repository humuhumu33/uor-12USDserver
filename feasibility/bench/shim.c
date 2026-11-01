/* Stands in for the SQLite B-tree shim: only the cost of crossing from Rust into separately compiled C. */
__attribute__((noinline)) unsigned long shim_mix(unsigned long a, unsigned long b) { return (a ^ b) + 1; }

unsigned long shim_loop(unsigned long n, unsigned long seed) {
    unsigned long v = seed;
    for (unsigned long i = 0; i < n; i++) v = shim_mix(v, i);
    return v;
}

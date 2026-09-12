// IEEE comparisons against NaN. The Zig C backend wraps each float comparison as
// `helper(a,b) <op> 0` (lt:<0, le:<=0, gt:>0, ge:>=0, eq:==0, ne:!=0). Pre-fix all
// comparisons lowered to ONE spaceship returning 0 for an unordered (NaN) compare;
// that is correct only for lt/gt — for le/ge/eq it yielded true (`0<=0`, `0>=0`,
// `0==0`) and for ne it yielded false (`0!=0`), so `NaN <= x` / `NaN == NaN` came
// out true and `NaN != NaN` false. Every ordered compare with NaN must be false;
// only `!=` is true.
var sink: f64 = 0;
fn rf(x: f64) f64 {
    sink += x;
    return x;
}

export fn run_test() i32 {
    const nan = rf(0.0) / rf(0.0);
    const inf = rf(1.0) / rf(0.0);
    const x = rf(5.0);

    if (nan < x) return 1;
    if (nan <= x) return 2;
    if (nan > x) return 3;
    if (nan >= x) return 4;
    if (nan == x) return 5;
    if (!(nan != x)) return 6; // must be true
    if (x < nan) return 7;
    if (x <= nan) return 8;
    if (x > nan) return 9;
    if (x >= nan) return 10;
    if (nan == nan) return 11;
    if (!(nan != nan)) return 12; // must be true

    // ordered comparisons among finite/inf still behave normally
    if (!(x < inf)) return 13;
    if (!(x <= inf)) return 14;
    if (!(inf > x)) return 15;
    if (!(inf >= inf)) return 16;
    if (!(inf == inf)) return 17;
    if (x == inf) return 18;
    if (!(x <= x)) return 19;
    if (!(x >= x)) return 20;
    return 0;
}

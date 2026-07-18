// Aggregate-in-aggregate by value: an array of structs each holding an array
// (the old Q9 gap — now works; locked in).
const Row = struct { cells: [3]i32 };
const Grid = struct { rows: [2]Row };
export fn run_test() i32 {
    var g: Grid = undefined;
    g.rows[0].cells[0] = 5;
    g.rows[0].cells[2] = 1;
    g.rows[1].cells[2] = 7;
    if (g.rows[0].cells[0] != 5 or g.rows[0].cells[2] != 1 or g.rows[1].cells[2] != 7) return 1;
    if (g.rows[0].cells[0] * 10 + g.rows[1].cells[2] != 57) return 2;
    return 0;
}

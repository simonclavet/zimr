# goban's go problems

Life-and-death problems in SGF, from Go Game Guru (https://gogameguru.com/), as the source property of each file says,
used in zimr with Go Game Guru's permission.

`source/` holds them as published, 422 of them: 140 easy, 140 intermediate and 140 hard, and two of no grade - the setup
in the root node, and the solution tree after it, its correct lines ending in a comment that begins "Correct". Their
names give their grade (`ggg-easy-01.sgf`).

The files beside this one are the problems goban plays: kill problems, black to play and capture one white stone, the
target, which a triangle (`TR`) marks; and life problems, black to play and save one black stone, which a square
(`SQ`) marks. `goban_problems_tool.zig` made them from the published ones, finding each target with goban's search:

- `<name>.sgf` - the problem as published, its setup and solution tree, with the triangle or the square added;
- `<name>-from-move-<n>.sgf` - the position before black's move n of the correct line, a shorter problem;
- `<name>-swapped.sgf` - a life problem with its colours swapped: the group that had to live is the target.

The two kinds made from a problem hold its stones, the target and a comment saying where they come from, and no
solution tree.

Three files keep the converter's work:

- `report.tsv` - one line for each published problem converted: what it was found to be, its target, the search's win
  rates, its later starts. A run skips the problems it has.
  (`zbuild goban-problems-convert -- <sgf files>`, the files from `source/`.)
- `difficulty.tsv` - how hard each problem's answer is to find: the iterations the search took to settle on one of the
  book's correct first moves for good.
  (`zbuild goban-problems-convert -- --measure <sgf files>`, the files beside this one.)
- `index.zig` - generated from the two: the families, by grade and then difficulty, and the lists of kill and life
  problems, which goban.zig imports. It is rewritten by every run; it is not edited by hand.

295 of the published problems are converted so far: all 140 easy, all 140 intermediate and 35 hard.

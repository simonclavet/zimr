# Record what the zimrnum / zimrrl split must conserve, by name: public declarations, test names, reference rows.
#   python3 src/notes/scripts/zimrrl_split_baseline.py > src/notes/zimrrl_split_baseline.txt
# After the split, the same script run over both libraries must give the same sets (each name in exactly one).
import re, sys
SOURCES = sys.argv[1:] or ["src/zimrnum.zig"]
PAGES = [s.replace("src/", "src/notes/tutorials/").replace(".zig", "-tutorial.html") for s in SOURCES]
public, tests, rows = [], [], []
lines_total = 0
for source in SOURCES:
    text = open(source).read()
    lines_total += text.count("\n")
    public += re.findall(r'^pub (?:fn|const|var) ([A-Za-z_][A-Za-z0-9_]*)', text, re.M)
    tests += re.findall(r'^test "([^"]*)"', text, re.M)
for page in PAGES:
    html = open(page).read()
    table = html[html.index('<h2 id="reference">'):]
    rows += re.findall(r'<tr><td><code>([^<]+)</code></td>', table)
print(f"# sources: {' '.join(SOURCES)}; lines: {lines_total}")
print(f"# public declarations: {len(public)}; tests: {len(tests)}; reference rows: {len(rows)}")
print("## public declarations")
print("\n".join(sorted(public)))
print("## tests")
print("\n".join(sorted(tests)))
print("## reference rows")
print("\n".join(sorted(rows)))

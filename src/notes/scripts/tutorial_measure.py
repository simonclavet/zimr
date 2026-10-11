import re, sys
path = sys.argv[1] if len(sys.argv) > 1 else "/home/claude/zimr/src/notes/tutorials/zimrrl-tutorial.html"
html = open(path).read()
html = re.sub(r'<div class="zn-source">.*?</div><!--/zn-source-->', '', html, flags=re.S)
html = html[:html.index('<h2 id="reference">')]
parts = re.split(r'(?=<h[23] id=")', html)
total_words = total_code = 0
chapter_words = {}
current = None
rows = []
for part in parts:
    m = re.match(r'<h([23]) id="([\w-]+)">(.*?)<a class', part)
    if not m:
        continue
    body = part[m.end():]
    code_lines = sum(c.count("\n") + 1 for c in re.findall(r'<pre>.*?</pre>', body, flags=re.S))
    prose = re.sub(r'<pre>.*?</pre>|<figure>.*?</figure>', '', body, flags=re.S)
    words = len(re.sub(r'<[^>]+>', ' ', prose).split())
    total_words += words; total_code += code_lines
    if m.group(1) == "2":
        current = m.group(3)
        chapter_words[current] = 0
    chapter_words[current] += words
    rows.append((m.group(1), m.group(2), m.group(3), words, code_lines))
if "--sections" in sys.argv:
    for level, anchor, title, words, code in rows:
        print(f"{'' if level == '2' else '   '}{title[:58]:58s} {words:5d}w {code:4d} code lines")
for chapter, words in chapter_words.items():
    print(f"{chapter[:50]:50s} {words:6d} words")
print(f"TOTAL prose words: {total_words}; code lines: {total_code}")

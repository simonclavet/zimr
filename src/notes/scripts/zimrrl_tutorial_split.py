#!/usr/bin/env python3
# Move the reinforcement-learning chapters from zimrnum-tutorial.html to zimrrl-tutorial.html.
#
#   python3 src/notes/scripts/zimrrl_tutorial_split.py --dry-run DIR    write both pages into DIR
#   python3 src/notes/scripts/zimrrl_tutorial_split.py --apply          rewrite both pages in the tree
#
# Blocks are found by their ids, never by line numbers. What moves:
#   chapter 16 (id rl)            -> zimrrl chapter 2, its sections 16.k -> 2.k, then 11.24 and 11.25 as 2.13, 2.14
#   chapter 18b (id rlpolicies)   -> zimrrl chapter 3, 18b.k -> 3.k
#   chapter 18d (id worldmodels)  -> zimrrl chapter 4, 18d.k -> 4.k; 18d.0, the course map, becomes the chapter's
#                                    unnumbered opening section
# Anchor ids do not change. zimrnum keeps a short pointer, with the same id and number, in place of each moved
# chapter and section, so its numbering and old links stay valid. Every invariant is checked before writing.
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
ZN_PAGE = os.path.join(ROOT, "src/notes/tutorials/zimrnum-tutorial.html")
ZRL_PAGE = os.path.join(ROOT, "src/notes/tutorials/zimrrl-tutorial.html")
ZN_FILE, ZRL_FILE = "zimrnum-tutorial.html", "zimrrl-tutorial.html"

analysis = open(os.path.join(ROOT, "src/notes/scripts/zimrrl_split_analysis.py")).read()
MOVED_NAMES = re.search(r'MOVES = """(.*?)"""', analysis, re.S).group(1).split()

CHAPTERS = [  # (id, the zimrnum chapter number, the zimrrl chapter number, the zimrrl title, the h2 that follows it)
    ("rl", "16", "2", "Reinforcement-learning building blocks", "autograd"),
    ("rlpolicies", "18b", "3", "Training policies", "diffusion"),
    ("worldmodels", "18d", "4", "World models: learning to imagine", "recipes"),
]
SECTIONS = [("minibatchorder", "11.24", "2.13"), ("truncation", "11.25", "2.14")]  # appended to zimrrl chapter 2


def fail(message):
    print("zimrrl_tutorial_split: " + message)
    sys.exit(1)


def line_of(lines, needle):
    hits = [i for i, line in enumerate(lines) if needle in line]
    if len(hits) != 1:
        fail(f"expected one line containing {needle!r}, found {len(hits)}")
    return hits[0]


def heading_text(line):
    """A heading's title, without its number and its anchor link."""
    inner = re.sub(r'<a class="anchor".*', '', re.sub(r'^<h[23] id="[^"]+">', '', line))
    return re.sub(r'^\d+[a-d]?(\.\d+)?\.?\s+', '', inner).strip()


def renumber(text):
    """Section references inside the moved chapters, mapped to zimrrl's numbers."""
    text = re.sub(r'\b18d\.(\d+)\b', lambda m: f"4.{m.group(1)}", text)
    text = re.sub(r'\b18b\.(\d+)\b', lambda m: f"3.{m.group(1)}", text)
    return text


def spell_moved_names(text):
    """`zn.<moved name>` becomes `zrl.<moved name>`, outside the generated source folds (regenerated anyway)."""
    pattern = re.compile(r'\bzn\.(' + "|".join(sorted(MOVED_NAMES, key=len, reverse=True)) + r')\b')
    return pattern.sub(lambda m: "zrl." + m.group(1), text)


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("--dry-run", "--apply"):
        fail("usage: --dry-run DIR | --apply")
    zn_lines = open(ZN_PAGE).read().split("\n")
    zrl_lines = open(ZRL_PAGE).read().split("\n")
    original_ids = set(re.findall(r'\bid="([\w-]+)"', "\n".join(zn_lines)))
    skeleton_ids = set(re.findall(r'\bid="([\w-]+)"', "\n".join(zrl_lines)))

    # ---- The blocks, by id ----
    blocks = {}
    for chapter_id, _, _, _, next_id in CHAPTERS:
        start = line_of(zn_lines, f'<h2 id="{chapter_id}">')
        end = line_of(zn_lines, f'<h2 id="{next_id}">')
        blocks[chapter_id] = (start, end)
    section_start = line_of(zn_lines, '<h3 id="minibatchorder">')
    section_end = line_of(zn_lines, '<h3 id="numericalgrad">')
    if line_of(zn_lines, '<h3 id="truncation">') not in range(section_start, section_end):
        fail("11.25 is not between 11.24 and 11.26")

    # ---- zimrrl's new chapters ----
    moved_html = []
    for chapter_id, old_number, new_number, title, _ in CHAPTERS:
        start, end = blocks[chapter_id]
        chapter = zn_lines[start:end]
        chapter[0] = f'<h2 id="{chapter_id}">{new_number}. {title}<a class="anchor" href="#{chapter_id}">#</a></h2>'
        out = []
        for line in chapter:
            m = re.match(r'^<h3 id="([\w-]+)">(\d+[a-d]?)\.(\d+) ', line)
            if m and m.group(2) == old_number:
                if chapter_id == "worldmodels" and m.group(3) == "0":
                    line = re.sub(r'^(<h3 id="[\w-]+">)18d\.0 ', r'\1', line)
                else:
                    line = line.replace(f'>{old_number}.{m.group(3)} ', f'>{new_number}.{m.group(3)} ', 1)
            out.append(line)
        if chapter_id == "rl":
            sections = zn_lines[section_start:section_end]
            for section_id, old, new in SECTIONS:
                k = next(i for i, line in enumerate(sections) if line.startswith(f'<h3 id="{section_id}">'))
                sections[k] = sections[k].replace(f'>{old} ', f'>{new} ', 1)
            out += [""] + sections
        moved_html += out
    text = "\n".join(moved_html)
    text = text.replace("Read it as a course: 18d.0 draws the agent once",
                        "Read it as a course: its opening section draws the agent once")
    text = spell_moved_names(renumber(text))
    # Section references live in prose; numbers in code and in measured tables (inside <pre>) are quantities.
    prose = re.sub(r'<svg.*?</svg>|<pre>.*?</pre>|<code>.*?</code>', '', text, flags=re.S)
    leftover = sorted(set(re.findall(r'\b(?:16|18b|18d)\.\d+\b|\b11\.2[45]\b', prose)))
    if leftover:
        fail(f"zimrnum section numbers left in the moved chapters: {leftover}")

    # ---- zimrrl's page: chapter 1, the moved chapters, the reference as chapter 5, a contents list ----
    reference_at = line_of(zrl_lines, '<h2 id="reference">')
    zrl_lines[reference_at] = zrl_lines[reference_at].replace(">2. Reference", ">5. Reference")
    page = zrl_lines[:reference_at] + text.split("\n") + [""] + zrl_lines[reference_at:]
    contents = []
    for line in page:
        h2 = re.match(r'^<h2 id="([\w-]+)">', line)
        h3 = re.match(r'^<h3 id="([\w-]+)">', line)
        if h2:
            contents.append(("h2", h2.group(1), heading_text(line)))
        elif h3:
            contents.append(("h3", h3.group(1), heading_text(line)))
    nav = ["<nav>", "<strong>Contents</strong>", "<ol>"]
    for index, (kind, anchor, title) in enumerate(contents):
        if kind == "h2":
            children = []
            for kind2, anchor2, title2 in contents[index + 1:]:
                if kind2 == "h2":
                    break
                children.append(f'<li><a href="#{anchor2}">{title2}</a></li>')
            if children:
                nav.append(f'  <li><a href="#{anchor}">{title}</a>')
                nav.append("    <ol>" + "\n        ".join(children) + "</ol></li>")
            else:
                nav.append(f'  <li><a href="#{anchor}">{title}</a></li>')
    nav += ["</ol>", "</nav>"]
    nav_start, nav_end = line_of(page, "<nav>"), line_of(page, "</nav>")
    page = page[:nav_start] + nav + page[nav_end + 1:]

    # ---- zimrnum's page: pointers in place of what moved ----
    zn_after = list(zn_lines)
    for chapter_id, old_number, new_number, title, _ in reversed(CHAPTERS):
        start, end = blocks[chapter_id]
        old_title = heading_text(zn_lines[start])
        zn_after[start:end] = [
            f'<h2 id="{chapter_id}">{old_number}. {old_title}<a class="anchor" href="#{chapter_id}">#</a></h2>',
            "",
            f'<p>This chapter is now <a href="{ZRL_FILE}#{chapter_id}">chapter {new_number} of the zimrrl tutorial</a>,'
            " with the reinforcement-learning library it describes.</p>",
            "",
        ]
    pointers = []
    for section_id, old, new in SECTIONS:
        heading = zn_lines[line_of(zn_lines, f'<h3 id="{section_id}">')]
        pointers += [
            f'<h3 id="{section_id}">{old} {heading_text(heading)}<a class="anchor" href="#{section_id}">#</a></h3>',
            "",
            f'<p>This section is now <a href="{ZRL_FILE}#{section_id}">{new} in the zimrrl tutorial</a>.</p>',
            "",
        ]
    zn_after[section_start:section_end] = pointers
    zn_text = "\n".join(zn_after)
    zn_text = zn_text.replace("<title>zimrnum — numerics, statistics, deep learning and RL for zimr</title>",
                              "<title>zimrnum — numerics, statistics and deep learning for zimr</title>")
    zn_text = spell_moved_names(zn_text)
    # A link that already pointed nowhere: no section covers `polyakUpdate`, so its name stays as code.
    broken = '<a href="#polyak"><code>polyakUpdate</code></a>'
    if zn_text.count(broken) != 1:
        fail("the #polyak link is not where it was")
    zn_text = zn_text.replace(broken, "<code>polyakUpdate</code>")
    # zimrnum's contents list: a moved chapter keeps one entry, pointing at its pointer.
    for chapter_id, _, _, _, _ in CHAPTERS:
        zn_text = re.sub(r'(  <li><a href="#' + chapter_id + r'">[^<]*</a>)\n    <ol>.*?</ol></li>',
                         r'\1</li>', zn_text, flags=re.S)

    # ---- Links that now point across the two pages ----
    zrl_text = "\n".join(page)
    zn_ids = set(re.findall(r'\bid="([\w-]+)"', zn_text))
    zrl_ids = set(re.findall(r'\bid="([\w-]+)"', zrl_text))

    def retarget(text, own_ids, other_ids, other_file):
        return re.sub(r'href="#([\w-]+)"',
                      lambda m: m.group(0) if m.group(1) in own_ids or m.group(1) not in other_ids
                      else f'href="{other_file}#{m.group(1)}"', text)
    zn_text = retarget(zn_text, zn_ids, zrl_ids, ZRL_FILE)
    zrl_text = retarget(zrl_text, zrl_ids, zn_ids, ZN_FILE)

    # ---- Invariants ----
    pointer_ids = {c[0] for c in CHAPTERS} | {s[0] for s in SECTIONS}
    if not original_ids <= (zn_ids | zrl_ids):
        fail(f"ids lost: {sorted(original_ids - zn_ids - zrl_ids)[:10]}")
    if (zn_ids & zrl_ids) - pointer_ids - {"reference", "what"}:
        fail(f"ids defined in both pages: {sorted((zn_ids & zrl_ids) - pointer_ids)[:10]}")
    if not skeleton_ids <= zrl_ids:
        fail("zimrrl's own ids were lost")
    for name, linked_text, own, other, other_ids in (("zimrnum", zn_text, zn_ids, ZRL_FILE, zrl_ids),
                                                     ("zimrrl", zrl_text, zrl_ids, ZN_FILE, zn_ids)):
        dangling = sorted({a for a in re.findall(r'href="#([\w-]+)"', linked_text) if a not in own})
        crossing = sorted({a for a in re.findall(r'href="' + re.escape(other) + r'#([\w-]+)"', linked_text)
                           if a not in other_ids})
        if dangling or crossing:
            fail(f"{name}: unresolved links {dangling} {crossing}")
    for name, page_text in (("zimrnum", zn_text), ("zimrrl", zrl_text)):
        prose = re.sub(r'<details class="src-fold">.*?</details>', '', page_text, flags=re.S)
        prose = re.sub(r'<tr><td><code>.*?</tr>', '', prose)
        stale = sorted(set(re.findall(r'\bzn\.(?:' + "|".join(MOVED_NAMES) + r')\b', prose)))
        if stale:
            fail(f"{name}: moved names still spelled zn.: {stale[:8]}")
    moved_h3 = len(re.findall(r'^<h3 id=', text, re.M))
    print(f"moved: {len(CHAPTERS)} chapters and {len(SECTIONS)} sections, {moved_h3} h3 sections, "
          f"{text.count(chr(10)) + 1} lines")
    print(f"zimrnum page: {zn_text.count(chr(10)) + 1} lines; zimrrl page: {zrl_text.count(chr(10)) + 1} lines")
    if sys.argv[1] == "--dry-run":
        os.makedirs(sys.argv[2], exist_ok=True)
        open(os.path.join(sys.argv[2], ZN_FILE), "w").write(zn_text)
        open(os.path.join(sys.argv[2], ZRL_FILE), "w").write(zrl_text)
        print(f"dry run written to {sys.argv[2]}")
    else:
        open(ZN_PAGE, "w").write(zn_text)
        open(ZRL_PAGE, "w").write(zrl_text)
        print("applied to both pages")


main()

#!/usr/bin/env python3
# Replace the bodies of tutorial sections by id, keeping each heading line as it is.
#
#   python3 src/notes/scripts/tutorial_replace_section.py PAGE DIR
#
# For every DIR/<id>.html, the body of the section `<h3 id="<id>">` (or `<h2 id="<id>">`, its opening up to the first
# h3) - everything after its heading line up to the next heading - is replaced by the file's contents. Source folds in
# the replaced body go with it; zimrnum_ref regenerates them. Writes nothing unless every id is found exactly once.
import os
import re
import sys

page_path, folder = sys.argv[1], sys.argv[2]
text = open(page_path).read()
replacements = {name[:-5]: open(os.path.join(folder, name)).read().strip("\n")
                for name in sorted(os.listdir(folder)) if name.endswith(".html")}
for anchor, body in replacements.items():
    heads = [m for m in re.finditer(r'^<h([23]) id="' + re.escape(anchor) + r'">[^\n]*\n', text, re.M)]
    if len(heads) != 1:
        sys.exit(f"tutorial_replace_section: {anchor}: expected one heading, found {len(heads)}")
    head = heads[0]
    following = re.search(r'^<h[23] id="', text[head.end():], re.M)
    end = head.end() + following.start() if following else len(text)
    text = text[:head.end()] + "\n" + body + "\n\n" + text[end:]
open(page_path, "w").write(text)
print(f"replaced {len(replacements)} section bodies: {', '.join(replacements)}")

#!/usr/bin/env python3
# Reorganise zimrrl-tutorial.html by the library's layers (step 1 of the organisational pass: structure only).
#
#   python3 src/notes/scripts/zimrrl_tutorial_reorganise.py --dry-run DIR    write the three changed files into DIR
#   python3 src/notes/scripts/zimrrl_tutorial_reorganise.py --apply          rewrite them in the tree
#
# Sections move whole, by id, and keep their ids. Sections that cover the same topic are placed next to each other;
# merging their prose is a later, hand-edited step. The world-model chapter becomes chapter 9 (4.k -> 9.k in prose
# and figure labels, never inside an attribute value). Every invariant is checked before anything is written.
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
ZRL_PAGE = os.path.join(ROOT, "src/notes/tutorials/zimrrl-tutorial.html")
ZN_PAGE = os.path.join(ROOT, "src/notes/tutorials/zimrnum-tutorial.html")
BMPC = os.path.join(ROOT, "src/robot_bmpc.zig")

# (chapter id, number, title, opening paragraphs, section ids in order). Titles of retitled sections follow below.
CHAPTERS = [
    ("first-agent", 2, "A first agent", """<p>Every algorithm in this library runs the same loop: act, score each action, update the policy, repeat.
This chapter shows the loop, then builds the smallest complete agent &mdash; a linear policy that learns to balance a
cartpole. The chapters after it take the loop apart, one piece at a time, in the order the library's source is
organised.</p>""", ["rl-shape", "rl-first"]),
    ("environments", 3, "Environments and episodes", """<p>An environment is where experience comes from. zimrrl's is the cartpole: a step function with no
hidden state, two tasks, and the two ways an episode can end, which every algorithm downstream has to keep
apart.</p>""", ["cartpole", "rl-tasks", "truncation", "rl-truncation"]),
    ("experience", 4, "Experience: rollouts, replay and advantages", """<p>Experience is stored before it is learned from. On-policy methods keep one rollout and discard it after the
update; off-policy methods keep a ring of past transitions and sample from it. Either way, each action is then scored
by how much better it did than expected, and the samples are visited in minibatches.</p>""",
     ["rl-collect", "rlreplay", "gae", "rlgae", "minibatchorder"]),
    ("policies", 5, "Policies", """<p>A policy is a distribution over actions. The distributions themselves live in zimrnum; this chapter is
about how reinforcement learning uses them: sampling to act, log-probabilities to learn, the tanh squash that keeps a
continuous action inside its bounds, and attention for observations that are sets.</p>""",
     ["dists", "rl-differentiable", "squashed", "rl-transformer"]),
    ("onpolicy", 6, "On-policy training: PPO and AWR", """<p>On-policy methods learn from the rollout the current policy has just collected. PPO limits how far one update
can move the policy; AWR regresses the policy onto its own better-than-expected actions.</p>""",
     ["rl-ppo", "rlppo", "ppo", "rl-awr"]),
    ("offpolicy", 7, "Off-policy training: DQN, SAC and TD3", """<p>Off-policy methods keep their data and learn from it many times. That is more sample-efficient, and it brings
one problem: a value function trained on its own estimates drifts upward. The methods in this chapter differ mainly in
how they counter that drift.</p>""", ["rl-offpolicy", "dqn", "sac", "td3-actor"]),
    ("imitation", 8, "Imitation and tracking", """<p>When the goal is to move like reference motion, the reward has to be learned or designed. This chapter covers
adversarial imitation, the gradient penalty that keeps its discriminator useful as a reward, and tracking rewards that
compare a motion with its reference.</p>""", ["rl-adversarial", "rl-secondorder", "rl-tracking"]),
]
RETITLE = {
    "cartpole": "Cartpole",
    "truncation": "How an episode ends: terminal and truncated",
    "rl-collect": "Rollouts and replay",
    "gae": "Advantages: GAE",
    "minibatchorder": "Minibatches",
    "squashed": "The squash correction",
    "rl-ppo": "PPO: what the clip is for",
    "ppo": "The PPO objective and its two health numbers",
    "dqn": "The DQN target",
    "sac": "SAC and its variants",
    "td3-actor": "A deterministic actor: TD3",
}
DROPPED = {"rl-endtoend"}      # its PPO-loss passage moves into "ppo"; the rest is testing detail
OLD_CHAPTER_IDS = {"rl", "rlpolicies"}


def fail(message):
    print("zimrrl_tutorial_reorganise: " + message)
    sys.exit(1)


def blocks_by_id(text):
    """Each h2 / h3 block (from its heading to the next heading of either level), keyed by id."""
    starts = [m.start() for m in re.finditer(r'^<h[23] id="', text, re.M)]
    out = {}
    for k, start in enumerate(starts):
        end = starts[k + 1] if k + 1 < len(starts) else len(text)
        anchor = re.match(r'<h[23] id="([\w-]+)"', text[start:]).group(1)
        out[anchor] = text[start:end]
    return out


def heading_title(block):
    line = block.split("\n", 1)[0]
    inner = re.sub(r'<a class="anchor".*', '', re.sub(r'^<h[23] id="[^"]+">', '', line))
    return re.sub(r'^\d+(\.\d+)?\.?\s+', '', inner).strip()


def renumber_world_models(text):
    """4.k -> 9.k in prose and in SVG text, never inside an attribute value (a circle's r="4.5" stays)."""
    return re.sub(r'(?<!=")(?<![\w.])4\.(\d{1,2})(?![\w"])', r'9.\1', text)


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("--dry-run", "--apply"):
        fail("usage: --dry-run DIR | --apply")
    page = open(ZRL_PAGE).read()
    reference_at = page.index('<h2 id="reference">')
    body, tail = page[:reference_at], page[reference_at:]
    first_h2 = body.index('<h2 id="rl">')
    head = body[:first_h2]
    blocks = blocks_by_id(body[first_h2:])
    world = body[body.index('<h2 id="worldmodels">'):]
    original_ids = set(re.findall(r'\bid="([\w-]+)"', page))

    # The PPO-loss passage of the dropped section joins the PPO objective's section.
    endtoend = blocks["rl-endtoend"]
    start = endtoend.index("<h4>The objective as a loss on the graph</h4>")
    stop = endtoend.index("and the gradient keeps lowering the ratio.</p>", start) + len(
        "and the gradient keeps lowering the ratio.</p>")
    ppo_loss = endtoend[start:stop]
    # Its code example's fold moves with it; zimrnum_ref regenerates every fold where the code now is.
    blocks["ppo"] = blocks["ppo"].rstrip("\n") + "\n\n" + ppo_loss + "\n\n"

    placed = [s for chapter in CHAPTERS for s in chapter[4]]
    old_sections = [a for a in blocks if a not in OLD_CHAPTER_IDS and not world.count(f'id="{a}"')]
    missing = sorted(set(old_sections) - set(placed) - DROPPED)
    if missing:
        fail(f"sections with no place: {missing}")

    out = [head.rstrip("\n"), ""]
    for chapter_id, number, title, opening, sections in CHAPTERS:
        out += [f'<h2 id="{chapter_id}">{number}. {title}<a class="anchor" href="#{chapter_id}">#</a></h2>', "",
                opening, ""]
        for k, section in enumerate(sections, start=1):
            block = blocks[section]
            title_now = RETITLE.get(section, heading_title(block))
            first_line, rest = block.split("\n", 1)
            # A section body that cites a world-model section (SequenceReplay in the replay section) follows it to 9.
            rest = renumber_world_models(rest)
            heading = f'<h3 id="{section}">{number}.{k} {title_now}<a class="anchor" href="#{section}">#</a></h3>'
            out += [heading + "\n" + rest.rstrip("\n"), ""]
    world_text = renumber_world_models(world)
    world_text = world_text.replace('<h2 id="worldmodels">4. ', '<h2 id="worldmodels">9. ', 1)
    out += [world_text.rstrip("\n"), ""]
    text = "\n".join(out) + "\n" + tail.replace(">5. Reference<", ">10. Reference<", 1)

    # The contents list, generated from the headings.
    contents = re.findall(r'^<h([23]) id="([\w-]+)">(.*?)<a class', text, re.M)
    nav = ["<nav>", "<strong>Contents</strong>", "<ol>"]
    for index, (level, anchor, title) in enumerate(contents):
        if level != "2":
            continue
        title = re.sub(r'^\d+\.\s+', '', title)
        children = []
        for level2, anchor2, title2 in contents[index + 1:]:
            if level2 == "2":
                break
            children.append(f'<li><a href="#{anchor2}">{re.sub(r"^[0-9.]+ ", "", title2)}</a></li>')
        if children:
            nav += [f'  <li><a href="#{anchor}">{title}</a>', "    <ol>" + "\n        ".join(children) + "</ol></li>"]
        else:
            nav.append(f'  <li><a href="#{anchor}">{title}</a></li>')
    nav += ["</ol>", "</nav>"]
    text = re.sub(r'<nav>.*?</nav>', "\n".join(nav), text, count=1, flags=re.S)

    # ---- Invariants ----
    ids = set(re.findall(r'\bid="([\w-]+)"', text))
    lost = sorted(original_ids - ids - DROPPED - OLD_CHAPTER_IDS)
    if lost:
        fail(f"ids lost: {lost}")
    dangling = sorted({a for a in re.findall(r'href="#([\w-]+)"', text) if a not in ids})
    if dangling:
        fail(f"links to ids that no longer exist: {dangling}")
    section, sub = 0, 0
    for m in re.finditer(r'^<h([23]) id="[\w-]+">(\d+)(?:\.(\d+))?[ .]', text, re.M):
        if m.group(1) == "2":
            section, sub = int(m.group(2)), 0
        else:
            sub += 1
            if int(m.group(2)) != section or int(m.group(3)) != sub:
                fail(f"heading {m.group(2)}.{m.group(3)} should be {section}.{sub}")
    if re.search(r'(?<!=")(?<![\w.])4\.\d{1,2}(?![\w"])', text[text.index('<h2 id="worldmodels">'):
                                                          text.index('<h2 id="reference">')]):
        fail("a world-model reference was not renumbered")

    # ---- robot_bmpc.zig and zimrnum's pointers ----
    bmpc = open(BMPC).read()
    bmpc = bmpc.replace("Chapter 4 of the zimrrl tutorial", "Chapter 9 of the zimrrl tutorial")
    bmpc = re.sub(r'(?<![\w.])4\.(\d{1,2})\b', r'9.\1', bmpc)
    zn = open(ZN_PAGE).read()
    for old, new in (
        ('<a href="zimrrl-tutorial.html#rl">chapter 2 of the zimrrl tutorial</a>',
         '<a href="zimrrl-tutorial.html#first-agent">chapters 2 to 8 of the zimrrl tutorial</a>, arranged by topic'),
        ('<a href="zimrrl-tutorial.html#rlpolicies">chapter 3 of the zimrrl tutorial</a>',
         '<a href="zimrrl-tutorial.html#first-agent">chapters 2 to 8 of the zimrrl tutorial</a>, arranged by topic'),
        ('<a href="zimrrl-tutorial.html#worldmodels">chapter 4 of the zimrrl tutorial</a>',
         '<a href="zimrrl-tutorial.html#worldmodels">chapter 9 of the zimrrl tutorial</a>'),
        ('<a href="zimrrl-tutorial.html#minibatchorder">2.13 in the zimrrl tutorial</a>',
         '<a href="zimrrl-tutorial.html#minibatchorder">4.5 in the zimrrl tutorial</a>'),
        ('<a href="zimrrl-tutorial.html#truncation">2.14 in the zimrrl tutorial</a>',
         '<a href="zimrrl-tutorial.html#truncation">3.3 in the zimrrl tutorial</a>'),
    ):
        if zn.count(old) != 1:
            fail(f"zimrnum pointer not found: {old[:60]}")
        zn = zn.replace(old, new)
    zn_links = set(re.findall(r'href="zimrrl-tutorial\.html#([\w-]+)"', zn))
    if zn_links - ids:
        fail(f"zimrnum links to zimrrl ids that do not exist: {sorted(zn_links - ids)}")
    for path, label in ((os.path.join(ROOT, "src/notes/tutorials/robot-mocap-tutorial.html"), "robot-mocap"),):
        other = set(re.findall(r'href="zimrrl-tutorial\.html#([\w-]+)"', open(path).read()))
        if other - ids:
            fail(f"{label} links to zimrrl ids that do not exist: {sorted(other - ids)}")

    print(f"chapters: {len(CHAPTERS) + 3} (1, 2-8 new, 9 world models, 10 reference); "
          f"sections placed: {len(placed)}; dropped: {sorted(DROPPED)}")
    print(f"zimrrl page: {text.count(chr(10)) + 1} lines")
    if sys.argv[1] == "--dry-run":
        target = sys.argv[2]
        os.makedirs(target, exist_ok=True)
        open(os.path.join(target, "zimrrl-tutorial.html"), "w").write(text)
        open(os.path.join(target, "zimrnum-tutorial.html"), "w").write(zn)
        open(os.path.join(target, "robot_bmpc.zig"), "w").write(bmpc)
        print(f"dry run written to {target}")
    else:
        open(ZRL_PAGE, "w").write(text)
        open(ZN_PAGE, "w").write(zn)
        open(BMPC, "w").write(bmpc)
        print("applied")


main()

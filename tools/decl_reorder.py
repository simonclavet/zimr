#!/usr/bin/env python3
"""decl_reorder.py - reorder a Zig file's top-level decls into declare-before-use
order, keeping strongly-connected components (genuine cycles) together so the only
remaining decl-order violations are within-SCC back-edges (the inescapable ones).

Usage: decl_reorder.py <deps_file> <zig_file> <out_file>
  deps_file: output of `decl_deps <zig_file>` (idx|first|last|name|refs)

Approach:
  * blocks tile the file: block_i = lines[start_i .. last_line_i], start_1=1,
    start_i = last_line_{i-1}+1. All inter-decl trivia (comments/blank lines/doc
    comments preceding a decl) ride in that decl's block. Trailing lines after the
    last decl are a fixed tail.
  * edges[i] = decls i references; a referenced decl must precede its referencer.
  * Tarjan SCC; topologically sort the condensation with a STABLE rule (Kahn,
    smallest original index among ready SCCs) for minimal disruption.
  * within each SCC keep original order. Emit blocks in the new order + tail.
Content is never edited - only whole blocks are permuted (verified by caller).
"""
import sys, re

def main():
    deps_path, zig_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    decls = []  # (idx, first, last, name, [refs])
    for line in open(deps_path):
        line = line.rstrip("\n")
        if not line: continue
        idx, first, last, name, refs = line.split("|", 4)
        ridx = [int(x) for x in refs.split(",") if x != ""]
        decls.append((int(idx), int(first), int(last), name, ridx))
    decls.sort(key=lambda d: d[0])
    n = len(decls)
    src = open(zig_path).read().split("\n")
    total = len(src)

    # tile blocks
    blocks = []
    start = 1
    for (idx, first, last, name, refs) in decls:
        assert start <= last, f"tiling broke at decl {idx} ({name}): start={start} last={last}"
        blocks.append(src[start-1:last])   # lines start..last inclusive (1-indexed)
        start = last + 1
    tail = src[start-1:]   # trailing lines after the last decl (kept fixed at end)

    # integrity precheck: blocks + tail reconstruct the file exactly
    recon = []
    for b in blocks: recon += b
    recon += tail
    assert recon == src, "block tiling does not reconstruct the source"

    # adjacency: edges[i] = set of decls i references (must precede i)
    edges = [set(refs) for (_,_,_,_,refs) in decls]

    # Tarjan SCC (iterative)
    index = [None]*n; low = [0]*n; onstack = [False]*n; stack = []
    comp = [None]*n; ncomp = 0; counter = 0
    for s in range(n):
        if index[s] is not None: continue
        work = [(s, iter(edges[s]))]
        index[s] = low[s] = counter; counter += 1; stack.append(s); onstack[s] = True
        while work:
            v, it = work[-1]
            advanced = False
            for w in it:
                if index[w] is None:
                    index[w] = low[w] = counter; counter += 1
                    stack.append(w); onstack[w] = True
                    work.append((w, iter(edges[w])))
                    advanced = True
                    break
                elif onstack[w]:
                    low[v] = min(low[v], index[w])
            if advanced: continue
            if low[v] == index[v]:
                while True:
                    w = stack.pop(); onstack[w] = False; comp[w] = ncomp
                    if w == v: break
                ncomp += 1
            work.pop()
            if work:
                low[work[-1][0]] = min(low[work[-1][0]], low[v])

    # condensation edges: comp(i) -> comp(j) for i references j (j must precede i)
    # We want an order where referenced comps come FIRST. Build "precede" DAG:
    # comp(j) must come before comp(i)  => edge comp(j) -> comp(i).
    cdeps = [set() for _ in range(ncomp)]   # cdeps[c] = comps that must come before c
    for i in range(n):
        for j in edges[i]:
            if comp[i] != comp[j]:
                cdeps[comp[i]].add(comp[j])
    # min original decl index per comp (for stable ordering)
    cminidx = [n]*ncomp
    for i in range(n):
        cminidx[comp[i]] = min(cminidx[comp[i]], i)
    # Kahn: indeg = number of comps that must precede c
    indeg = [0]*ncomp
    succ = [set() for _ in range(ncomp)]   # c -> comps that depend on c
    for c in range(ncomp):
        for p in cdeps[c]:
            succ[p].add(c)
    for c in range(ncomp):
        indeg[c] = len(cdeps[c])
    import heapq
    ready = [cminidx[c] << 20 | c for c in range(ncomp) if indeg[c] == 0]
    heapq.heapify(ready)
    order_comps = []
    while ready:
        key = heapq.heappop(ready)
        c = key & ((1<<20)-1)
        order_comps.append(c)
        for d in sorted(succ[c]):
            indeg[d] -= 1
            if indeg[d] == 0:
                heapq.heappush(ready, cminidx[d] << 20 | d)
    assert len(order_comps) == ncomp, "condensation is not a DAG (Tarjan bug)"

    # new decl order: comps in topo order; within a comp, original index order
    bycomp = {}
    for i in range(n):
        bycomp.setdefault(comp[i], []).append(i)
    new_order = []
    for c in order_comps:
        new_order += sorted(bycomp[c])

    # emit
    out = []
    for i in new_order:
        out += blocks[i]
    out += tail
    open(out_path, "w").write("\n".join(out))

    # report: how many decls remain "used before declared" under new order
    pos = {i: p for p, i in enumerate(new_order)}
    viol = 0
    for i in range(n):
        for j in edges[i]:
            if pos[j] > pos[i]:   # referenced j comes after referencer i
                viol += 1
                break
    print(f"decls={n} sccs={ncomp} est_back_referenced_decls={viol}")

if __name__ == "__main__":
    main()

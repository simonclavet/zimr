import numpy as np
from scipy.optimize import minimize, minimize_scalar
from scipy.special import logsumexp

def dual_objective(v, beta, delta):
    n = len(v)
    return -beta * (logsumexp(-v / beta) - np.log(n)) - beta * delta

def robust_dual(v, delta, beta_cap=None):
    """sup over beta > 0 (or (0, cap]) of the dual - searched on log beta; the beta -> 0 limit is min(v)."""
    scale = max(np.ptp(v), 1e-12)
    top = np.log(beta_cap) if beta_cap else np.log(scale) + 25
    grid = np.linspace(np.log(scale) - 25, top, 2000)
    values = np.array([dual_objective(v, np.exp(g), delta) for g in grid])
    k = int(np.argmax(values))
    lo, hi = grid[max(k - 1, 0)], grid[min(k + 1, len(grid) - 1)]
    res = minimize_scalar(lambda g: -dual_objective(v, np.exp(g), delta), bounds=(lo, hi), method="bounded",
                          options={"xatol": 1e-13})
    best, best_beta = -res.fun, np.exp(res.x)
    if v.min() > best:          # the supremum is the beta -> 0 limit: the minimum
        return v.min(), 0.0
    return best, best_beta

def robust_primal(v, delta):
    """min over reweightings p of sum p v, subject to KL(p || uniform) <= delta - a generic solver, no duality.
    p = softmax(u) keeps every weight positive (the constraint's gradient stays finite), and a result counts if it
    is FEASIBLE, whatever the optimiser's success flag says."""
    n = len(v)
    def weights(u):
        e = np.exp(u - u.max())
        return e / e.sum()
    def kl(u):
        p = weights(u)
        return np.sum(p * np.log(np.maximum(p, 1e-300) * n))
    cons = [{"type": "ineq", "fun": lambda u: delta - kl(u)}]
    best = None
    starts = [np.zeros(n)] + [np.random.default_rng(s).normal(0, 1, n) for s in range(6)]
    starts += [-(v - v.mean()) / max(np.ptp(v), 1e-12) * k for k in (1.0, 5.0, 20.0)]
    for start in starts:
        res = minimize(lambda u: weights(u) @ v, start, method="SLSQP", constraints=cons,
                       options={"ftol": 1e-15, "maxiter": 5000})
        if kl(res.x) <= delta + 1e-9:
            value = weights(res.x) @ v
            best = value if best is None else min(best, value)
    return best

rng = np.random.default_rng(7)
n = 8
print("1. dual vs primal (8 values ~ 100 +- 15), worst relative gap over 40 draws x 7 deltas:")
worst = 0.0
for _ in range(40):
    v = rng.normal(100.0, 15.0, n)
    for delta in [0.01, 0.1, 0.5, 1.0, 2.0, np.log(n), 5.0]:
        d, _ = robust_dual(v, delta)
        p = robust_primal(v, delta)
        worst = max(worst, abs(d - p) / np.ptp(v))
print(f"   max |dual - primal| / spread = {worst:.2e}")

print("2. limits:")
v = rng.normal(100.0, 15.0, n)
d0, _ = robust_dual(v, 1e-10)
print(f"   delta = 1e-10: robust - mean = {d0 - v.mean():+.2e}")
for delta in [np.log(n), np.log(n) + 0.5, 10.0]:
    d, b = robust_dual(v, delta)
    print(f"   delta = {delta:.3f}: robust - min = {d - v.min():+.2e} (beta* = {b:.3g})")
d, _ = robust_dual(v, np.log(n) - 0.2)
print(f"   delta = log N - 0.2: robust - min = {d - v.min():+.3f} (just below log N: not yet the minimum)")

print("3. small delta: (mean - robust) / (sqrt(2 delta) * std) -> 1, std with 1/N:")
for delta in [1e-2, 1e-3, 1e-4, 1e-5]:
    d, _ = robust_dual(v, delta)
    print(f"   delta = {delta:.0e}: ratio = {(v.mean() - d) / (np.sqrt(2 * delta) * v.std()):.5f}")

print("4. R1's beta = 10 with N = Nf x Nv = 8: mean - beta * sigma_hat, sigma_hat = std / sqrt(N):")
below_biased = below_unbiased = 0
draws = 2000
for _ in range(draws):
    w = rng.normal(100.0, 15.0, n)
    below_biased += (w.mean() - 10.0 * w.std() / np.sqrt(n)) < w.min()
    below_unbiased += (w.mean() - 10.0 * w.std(ddof=1) / np.sqrt(n)) < w.min()
print(f"   penalised estimate BELOW the worst head: {below_biased / draws:.1%} (std 1/N), "
      f"{below_unbiased / draws:.1%} (std 1/(N-1))")
print(f"   the small-delta mapping delta = beta^2 / (2N) = {100 / 16:.2f}, against log N = {np.log(n):.3f}")

print("5. concavity of the dual in beta (max second difference over a grid, 40 draws, 3 deltas):")
worst_curvature = -np.inf
for _ in range(40):
    w = rng.normal(100.0, 15.0, n)
    for delta in [0.05, 0.5, 1.5]:
        betas = np.exp(np.linspace(np.log(0.05), np.log(1e4), 600))
        f = np.array([dual_objective(w, b, delta) for b in betas])
        # second differences on a log grid, scaled to be comparable
        second = f[2:] - 2 * f[1:-1] + f[:-2]
        chord = (f[2:] + f[:-2]) / 2 - f[1:-1]
        worst_curvature = max(worst_curvature, np.max(chord))
print(f"   max (chord midpoint - function) = {worst_curvature:.2e}  (<= 0: concave along the grid)")

print("6. gradient: finite differences vs the tilted weights w_i ~ exp(-v_i / beta*):")
v = rng.normal(100.0, 15.0, n)
delta = 0.3
d, beta_star = robust_dual(v, delta)
weights = np.exp(-(v - v.min()) / beta_star)
weights /= weights.sum()
h = 1e-5
fd = np.array([(robust_dual(v + h * np.eye(n)[i], delta)[0] - robust_dual(v - h * np.eye(n)[i], delta)[0]) / (2 * h)
               for i in range(n)])
print(f"   max |finite difference - weight| = {np.max(np.abs(fd - weights)):.2e}; weights sum to {weights.sum():.12f}")

print("7. DR-SAC's cap beta <= 1, returns ~ 100 +- 15, delta = 0.1:")
v = rng.normal(100.0, 15.0, n)
exact, _ = robust_dual(v, 0.1)
capped, _ = robust_dual(v, 0.1, beta_cap=1.0)
print(f"   mean {v.mean():.2f}, min {v.min():.2f}; exact robust {exact:.2f}; capped at beta 1: {capped:.2f}")

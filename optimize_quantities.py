#!/usr/bin/env python3
"""
产品数量优化器 — Product Quantity Optimizer
=============================================

已知 4 个产品的最高销量和单价。求实际销量（0 到最高销量，精确到 0.001）
使得 sum(销量 × 单价) 最接近 871637.99。

Products:
  P1: max=292.080, price=2398.0
  P2: max=292.070, price=2997.5
  P3: max= 18.130, price=5341.0
  P4: max=218.738, price=1471.5
"""

from math import gcd
import sys


def ceil_div(a, b):
    return -((-a) // b)


# ── Input ─────────────────────────────────────────────────────────────────
max_qty = [292.08, 292.07, 18.13, 218.738]
price   = [2398.0, 2997.5, 5341.0, 1471.5]
target  = 871637.99

# Scale: qty×1000 (3dp), price×10 (.5 handling), total = ×10000
QSC, PSC = 1000, 10
TSC = QSC * PSC

N = [int(q * QSC) for q in max_qty]
P = [int(p * PSC) for p in price]
T = int(round(target * TSC))

a1, a2, a3, a4 = P
n1m, n2m, n3m, n4m = N

# ── Theory ────────────────────────────────────────────────────────────────
# gcd(a1,a2,a3,a4) = 545.  T % 545 = 335.
# sum = 545 × (44·n1 + 55·n2 + 98·n3 + 27·n4)
# Since 335 ≠ 0, NO exact solution exists.
# Closest: T_best = 545 × round(T/545) = T + 210  → error = 0.021

G = gcd(gcd(a1, a2), gcd(a3, a4))
T_best = G * (T // G + 1)  # = T + 210
MIN_ERR = (T_best - T) / TSC  # = 0.021
S0 = T_best // G  # target for 44·n1 + 55·n2 + 98·n3 + 27·n4

print(f"缩放后目标值 T = {T}")
print(f"公因子 G = {G}, T % G = {T % G}")
print(f"理论最小误差 = {MIN_ERR:.6f}")
print()

# ── Search ────────────────────────────────────────────────────────────────
# Equation: 44·n1 + 55·n2 + 98·n3 + 27·n4 = S0
# For each n3:  S' = S0 - 98·n3
# Solve: 44·n1 + 55·n2 + 27·n4 = S'
#
# n4 ≡ 9·S' (mod 11)  →  n4 = n4_mod + 11·k
# For each n4: T12 = (S' - 27·n4) / 11
# Solve 4·n1 + 5·n2 = T12  (general: n1 = -T12+5t, n2 = T12-4t)

print("搜索最优解...")

best_solutions = []

# Strategy: iterate n3 from max (smallest S', easiest bounds)
for n3 in range(n3m, -1, -1):
    S_prime = S0 - 98 * n3
    if S_prime < 0:
        continue

    n4_mod = (9 * S_prime) % 11
    max_k = (n4m - n4_mod) // 11
    if max_k < 0:
        continue

    # Try n4 from large to small (large n4 → small T12 → easier bounds)
    for k in range(max_k, -1, -1):
        n4 = n4_mod + 11 * k
        rest = S_prime - 27 * n4
        if rest < 0:
            continue
        if rest % 11 != 0:
            continue

        T12 = rest // 11

        # Solve 4·n1 + 5·n2 = T12 within bounds
        t_lo = max(ceil_div(T12, 5), ceil_div(T12 - n2m, 4))
        t_hi = min((n1m + T12) // 5, T12 // 4)
        if t_lo > t_hi:
            continue

        t = t_lo
        n1 = -T12 + 5 * t
        n2 = T12 - 4 * t

        if not (0 <= n1 <= n1m and 0 <= n2 <= n2m):
            continue

        # Valid solution found
        actual_scaled = n1*a1 + n2*a2 + n3*a3 + n4*a4
        actual = actual_scaled / TSC
        err = abs(actual - target)
        q = [n1/QSC, n2/QSC, n3/QSC, n4/QSC]

        best_solutions.append({
            "q": q, "err": err, "sum": actual,
            "scaled_err": abs(actual_scaled - T),
        })

        # Print this solution
        print(f"  解 #{len(best_solutions):2d}: "
              f"({q[0]:8.3f}, {q[1]:8.3f}, {q[2]:8.3f}, {q[3]:8.3f})  "
              f"总和={actual:.6f} 误差={err:.6f}")

        # Collect more solutions with different n3
        break  # only first valid n4 per n3

    if n3 % 5000 == 0:
        sys.stdout.write(f"\r  进度: n3={n3}/{n3m} 已找到{len(best_solutions)}个解")
        sys.stdout.flush()

print(f"\r  进度: n3={n3m}/{n3m} 完成. 找到 {len(best_solutions)} 个解")
print()

# ── Output ────────────────────────────────────────────────────────────────
# Group by error
by_err = {}
for s in best_solutions:
    by_err.setdefault(s["err"], []).append(s)

best_err = min(by_err.keys())
best_list = by_err[best_err]

print("=" * 68)
print(f"最优解 (误差 = {best_err:.6f}, 共 {len(best_list)} 个):")
print("=" * 68)
print()

# Show the first best solution in detail
s = best_list[0]
q = s["q"]

print(f"  目标总和: {target:>10.6f}")
print(f"  实际总和: {s['sum']:>10.6f}")
print(f"  绝对误差: {s['err']:>10.6f}")
print()

header = f"  {'产品':>6}  {'销量':>8}  {'单价':>8}  {'小计':>12}  {'上限':>8}  {'状态':>10}"
print(header)
print("  " + "─" * len(header))
for i in range(4):
    line_sum = q[i] * price[i]
    status = "=上限" if abs(q[i] - max_qty[i]) < 0.001 else \
             "=0" if q[i] < 0.001 else \
             "正常"
    print(f"  P{i+1:>5}  {q[i]:>8.3f}  {price[i]:>8.1f}  {line_sum:>12.6f}  "
          f"{max_qty[i]:>8.3f}  {status:>10}")

print("  " + "─" * len(header))
total = sum(q[i] * price[i] for i in range(4))
print(f"  {'合计':>6}  {'':>8}  {'':>8}  {total:>12.6f}")
print()

print(f"  ★ 达到理论最小误差 {MIN_ERR:.6f}") if abs(best_err - MIN_ERR) < 1e-9 else None
print()

# ── Show diverse alternatives ────────────────────────────────────────────
if len(best_list) > 1:
    print(f"其他最优解 (误差 = {best_err:.6f}):")
    print()

    # pick some diverse solutions (different q3 values)
    shown_q3 = set()
    count = 0
    for s in best_list:
        q3_key = round(s["q"][2], 2)
        if q3_key in shown_q3:
            continue
        shown_q3.add(q3_key)
        q = s["q"]
        parts = [f"P{i+1}={q[i]:.3f}" for i in range(4)]
        print(f"  ({', '.join(parts)})  总和={s['sum']:.6f}")
        count += 1
        if count >= 5:
            break
    print()

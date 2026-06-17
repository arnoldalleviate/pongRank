# Season 0.5 — ELO Update

**What changed:** ratings now move on *how decisively* a match was played, not just who won. Close matches barely shift ratings; blowouts and dominant series move them the most. Series are weighted more than single games, and the rating floor dropped to **900**.

This came straight from player feedback: a **2–1 loss felt the same as a 2–0**, and a coin-flip match that came down to an overtime decider shouldn't swing ratings like a blowout. It shouldn't — so it no longer does.

---

## The old model

ELO moved on a **binary result** — `1` for the match winner, `0` for the loser — scaled by a margin multiplier that could only ever *amplify* a blowout, never *shrink* a nail-biter. Net effect:

- A **2–1 loss = a 2–0 loss** (same `0`).
- A **coin-flip** that went to overtime moved your rating the **same** as a clean win.
- A **best-of-3 series** counted the same as a single quick game.

---

## The new model — "margin as score"

Instead of win/loss, the **result itself is a sliding scale** from a draw to a decisive win, set by the total-point margin of the match:

```
margin       = (winner_points − loser_points) / total_points        # whole match
decisiveness = clamp( margin / decisiveness_full , 0 … 1 )           # 0 = coin-flip, 1 = domination
S_winner     = 0.5 + 0.5 × decisiveness                              # 0.5 … 1.0  (winning never costs you)
S_loser      = 1 − S_winner

ΔELO = K × (S − Expected)        # Expected = standard ELO win-probability from the rating gap
```

- **Coin-flip / OT decider** → `decisiveness ≈ 0` → `S ≈ 0.5` → treated like a draw → **almost no shift**.
- **Blowout** → `decisiveness ≈ 1` → `S ≈ 1.0` → **full shift**.
- The winner is **floored at `S = 0.5`** — winning the match can never *lower* your rating, even if you squeaked it on fewer points.

### Series are worth more
A best-of-3 carries `series_k_mult` × the K of a single game (currently **2×**), so a *dominant series* moves ratings about twice as much as a *dominant single game*. A close series stays close to zero either way.

### Lower rating floor (1000 → 900)
With the starting rating and the floor both at 1000, weaker players got pinned at 1000 and the math treated them as average — so **beating a pinned player was over-rewarded**. Dropping the floor to 900 lets ratings actually sink, so a win over a weaker player correctly pays less.

---

## Before vs. after

Two evenly-rated 1000 players, K = 40, defaults `decisiveness_full = 0.5`, `series_k_mult = 2`:

| Match | Old shift | **New shift** |
|-------|-----------|---------------|
| Single game, deuce (12–10) | ±20 | **±4** |
| Single game, 11–7 | ±20 | **±9** |
| Single game, blowout (11–2) | ±20 | **±20** |
| Series 2–0, two 11–9 games | ±20 | **±15** |
| Series 2–0, blowouts (11-3, 11-4) | ±20 | **±40** |
| **Series 2–1, OT decider** (11-9, 9-11, 12-10) | ±20 | **±3** |

The bottom row is the "fair matchup" players flagged — it barely moves now, while a true beatdown moves more than it ever did.

### Worked example — the 2–1 to overtime
`11-9, 9-11, 12-10` → winner scored **32**, loser **30** → margin `2 / 62 ≈ 0.032`.
`decisiveness = 0.032 / 0.5 ≈ 0.065` → `S_winner ≈ 0.53`.
Series K = 40 × 2 = 80 → `ΔELO = 80 × (0.53 − 0.50) ≈ ±3`.

Nearly a wash — exactly what a coin-flip should be.

---

## Tuning

All three are per-season levers, so they get re-tuned as Season 0 accumulates real games:

| Lever | Default | Effect |
|-------|---------|--------|
| `decisiveness_full` | 0.5 | Point-margin ratio that counts as "total domination." Lower = swingier. |
| `series_k_mult` | 2.0 | How much more a series moves ratings vs. a single game. |
| `elo_floor` | 900 | Lowest a rating can fall. |

> Numbers above are the current settings and will be calibrated further as more matches are played.


# Thank you so much for participating!

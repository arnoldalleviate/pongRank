# PROJECT CONTEXT — Ping Pong League

> Handoff doc. Drop this in the repo root. If you're a Claude/Claude Code session
> reading this fresh: this captures every decision already made with the user.
> Honor it. Don't re-litigate settled choices. Build steps 4–8 (see end).
> The user's standing instruction throughout has been: **take no liberties —
> confirm choices, don't silently decide.** Flag conflicts instead of papering over them.

---

## 1. What this is
A web app to track casual ping pong: live match scoring, player records, ELO
ratings (explicitly "comical / talking points," pool ≤ 20 players), seasons,
a table queue, and tournaments.

## 2. Architecture (LOCKED — "Option C")
- **Frontend:** Nuxt 3, built as a **static SPA**, hosted on **GitHub Pages**.
- **Backend:** **Supabase is the entire backend** — Postgres + Realtime + role
  enforcement. **There is NO Go backend and no custom server.** (We evaluated a
  Go backend; GitHub Pages can't run Go, so we chose Supabase-as-backend instead.
  Don't reintroduce Go.)
- **No logins.** Three roles via **access codes**:
  - `viewer` — reads everything (no code needed)
  - `official` — can log game scores (needs official code)
  - `commissioner` — can do everything (needs commissioner code)
  - **Write-permission split (refined 2026-06-16):** _official+_ runs matches —
    `start_match`, `cancel_match`, in-match scoring (`start_game`, `add_point`,
    `remove_last_point`, `flip_point`, `flip_first_server`, `submit_game_score`,
    `complete_match`), and tournament bracket play (`start_tournament_match`,
    `complete_tournament_match`). _commissioner-only_ — roster (`add_player`,
    `set_player_active`), seasons (`create_season`, `activate_season`,
    `set_season_config`, `end_season`), codes (`set_access_codes`), tournament
    setup (`create_tournament`, `set_tournament_seeds`, `start_tournament`).
    NOTE: `add_player` is commissioner (overrides its `official+` default in
    `01_schema.sql`); match create/cancel moved commissioner → official 2026-06-16.
- **Role enforcement is server-side and real, not cosmetic:** RLS allows public
  SELECT but has **no write policies**; every mutation goes through a
  `SECURITY DEFINER` rpc that checks the passed code via `verify_access` /
  `require_role` against `app_settings`. When adding any new write path, add a
  new rpc following that pattern — never open direct table writes.
- **Realtime = Supabase Realtime client subscriptions** (WebSocket-based). The
  user wanted "WebSocket for practice"; this is satisfied by writing client
  subscription code, not by hosting a socket server.
- **Frontend security:** only the **anon public** key ships in the browser
  (it's public by design — that's why RLS matters). The **service_role key must
  never touch the frontend.**

## 3. Match rules (LOCKED — these are the user's house rules)
- **Quick** match = 1 game. **Series** = best of 3 (first to win **2 games**).
- **Game:** first to **11**, must **win by 2** (12-10, 13-11, …).
- **Serving:** server switches after **every 5 serves**. At **10-10 (overtime),
  each player serves 2 then switches**, still win by 2.
- Anyone may serve first.
- **Two score-entry modes:** (a) **live point-by-point** logging — records who
  served and who scored each point, which powers heatmaps / color-coded tables;
  (b) **quick final-score upload** — game scores only, no point breakdown (for
  matches the commissioner didn't watch live).

## 4. ELO config (LOCKED)
- Start rating **1000**.
- **K-factor is a commissioner lever.** Defaults: **week 1 = stable**
  (`k_stable`, default 20), **week 2+ = swingy** (`k_swingy`, default 40), flip
  at `swingy_after_days` (default 7). `k_override` hard-overrides when set.
  (Default 7-day cutover was proposed and not contested — adjustable.)
- **Margin of victory affects ELO** (`mov_enabled`, `mov_weight` 0.5,
  `mov_cap` 1.75) so a 11-2 blowout moves ratings a bit more than an 11-9 grind,
  capped to stay sane.
- Standard expected-score math means **strong-beats-weak = small gain, upset =
  big swing** automatically.
- **ELO updates once per MATCH** (not per game), computed **server-side in a DB
  rpc at match completion** — never in the client.
- **First season has a rating floor of 1000** (`elo_floor`).

## 5. Seasons (LOCKED)
- Commissioner sets each season's timeline (2-week / 1-month / custom dates).
- On new season: **full reset** of ELO, W/L record, and rank.
- Before reset: **archive** the prior season's ELO, W/L, and rank. Implemented by
  freezing `final_rank` on the old `player_season_stats` rows and flipping the
  season to `archived` (those rows ARE the archive — past seasons remain queryable).
- `activate_season` rpc already does: archive current → activate chosen → create
  fresh 1000-rated stat rows for all active players.

## 6. Tournaments (LOCKED)
- Build **single-elimination** fully and live.
- **Wire the schema/types for double-elim and round-robin** so they switch on
  later without migration (`tournament_matches` already has `loser_next_match_id`,
  `loser_next_slot`, a `round_robin` bracket type, and `group_id`).
- **Seeding from ELO by default; commissioner can override manually.**

## 7. Queue (LOCKED)
- A line of players for the table. `queue` table + `table_state`
  (`open` / `ready` / `in_use`) on `app_settings`.

## 8. Design (LOCKED)
- **Company colors: blue & yellow.** Opposing players are **blue vs yellow**.
- Deep-navy "arena" background. Type roles: **Anton** (scoreboard/display),
  **Inter** (UI), **Spline Sans Mono** (stat numbers). Tokens live in
  `assets/css/main.css`.

---

## 9. Data model (already in SQL — don't recreate, extend)
Tables: `players` (identity only), `seasons` (holds all ELO levers),
`player_season_stats` (per-season live stats; past rows = archive), `matches`,
`games`, `points` (point-by-point: server_id + scorer_id), `queue`,
`tournaments`, `tournament_participants`, `tournament_matches`, `app_settings`
(single row: active season, codes, table_state, current_match_id).
Views: `v_current_standings`, `v_head_to_head`.
Helpers/rpcs already present: `verify_access`, `require_role`, `role_rank`,
`add_player`, `create_season`, `get_public_settings`, `whoami`,
`set_access_codes`, `set_table_state`, `activate_season`.

---

## 10. What's already BUILT (Steps 1–3, verified)
- **`01_schema.sql`** — full schema, enums, views, RLS (read-all / deny-write),
  access-code helpers, example rpcs.
- **`02_setup.sql`** — hardens codes out of browser reach (`get_public_settings`,
  `whoami`), config rpcs, adds Realtime publication tables.
- **`02_supabase_setup.md`** — click-by-click Supabase setup runbook (create
  project, run SQL, set codes, add players, activate Season 1, smoke test).
- **Nuxt scaffold** (builds clean, GitHub Pages output verified):
  - `nuxt.config.ts` — `ssr:false`, `nitro: github_pages` preset, `app.baseURL`
    (the ONE place to set the repo name — currently `/pingpong-league/`), Google
    fonts.
  - `plugins/supabase.client.ts`, `composables/useSupabase.ts`,
    `composables/useRole.ts` (whoami + localStorage; UI gating only, rpcs re-check).
  - `app.vue`, `layouts/default.vue` (top bar, role pill, code entry).
  - `pages/index.vue` — working **Leaderboard** reading `v_current_standings`.
  - `pages/matches.vue`, `queue.vue`, `tournaments.vue` — **placeholders**.
  - `.github/workflows/deploy.yml` — Pages deploy (reads `NUXT_PUBLIC_*` from
    Actions **Variables**, not Secrets).
  - `.env.example`, `README.md`.

### Deploy facts (so you don't relearn them)
- `app.baseURL` MUST equal `/<repo-name>/` exactly or Pages 404s on refresh.
  (Use `/` only for a custom domain or `username.github.io` root.)
- `NUXT_PUBLIC_SUPABASE_URL` / `NUXT_PUBLIC_SUPABASE_KEY` are needed **at build
  time**; set as repo Actions Variables. Pages Source must be "GitHub Actions."
- `localStorage` is fine here — this is a real deployed app, not an in-chat artifact.

---

## 11. What's LEFT to build (Steps 4–8)
**Step 4 — Core app (next up).**
  - Players management UI (add/retire) — **commissioner-only** (see §2 split).
  - Full leaderboard.
  - **Live scoreboard**: tap-to-score, serve indicator + serve-switch logic
    (every 5; at 10-10 each serves 2), win-by-2 to 11, Series best-of-3, undo,
    Realtime sync across devices.
  - **ELO engine** as DB rpcs: e.g. `start_match`, `add_point`,
    `submit_game_score` (quick upload), `complete_match` (computes ELO with the
    K levers + MoV, updates `player_season_stats`, writes the ELO snapshot onto
    `matches`). All code-gated.
**Step 5 — Seasons:** create/manage UI, reset + archive flow (rpc exists), view
  past-season archives + frozen ranks.
**Step 6 — Tournaments:** single-elim live (seed from ELO + manual override,
  bracket UI, advancement); leave double-elim/round-robin wired but off.
**Step 7 — Analytics:** head-to-head view, serve heatmaps (from `points`),
  color-coded tables; finish both entry modes.
**Step 8 — Deploy:** end-to-end verification pass.

---

## 12. Open items to confirm with the user
- **Repo name** (sets `baseURL`) — still a placeholder `pingpong-league`.
- `swingy_after_days = 7` default — confirm or change.

## 13. How to work with this codebase
- Next-step files are generated, then the user drops them into the project.
  Always state the exact file path for each file.
- Keep writes behind code-checked `SECURITY DEFINER` rpcs.
- Compute ELO server-side at match completion, not client-side.
- Respect the user's "no liberties" instruction: surface conflicts, confirm
  before deciding.

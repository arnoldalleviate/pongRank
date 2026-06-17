# Ping League 🏓

A casual ping pong tracker: live match scoring, ELO ratings (comical/talking
points, not serious), seasons, tournaments, and a table queue. Static Nuxt 3 SPA
on GitHub Pages, with **Supabase as the entire backend** (Postgres + Realtime +
role enforcement) — no server of our own to run.

**Live:** https://arnoldalleviate.github.io/pongRank/

---

## Features

### Leaderboard
- Live season standings: ELO, W–L, games won/lost, point differential, streak.
- **Peak ELO on hover** over a player's rating (keeps the table uncluttered).
- The two players from the most recent completed match get a soft glow.
- Realtime — any completed match updates every open device instantly.

### Live scoring & Officiate dashboard
- Tap-to-score panels for an official to run a match in real time.
- **Serve tracking** — 5 serves each pre-deuce, 2 each from 10-10; win-by-2 to 11.
- **Point timeline** grouped by service block, with **tap-to-flip** to correct a
  mis-scored point, and **⇄ Swap server** to fix the first server (within the
  first 5 serves).
- Undo, finish, and **cancel-with-reason**.
- A site-wide **ESPN-style scorebug** lives in the top bar whenever a match is
  on, so anyone can browse the site and still follow the score. Confetti on win.

### Match entry — two modes
- **Live point-by-point** — records who served and who scored each point (feeds
  future serve heatmaps / analytics).
- **Quick final-score upload** — game scores only, for matches nobody officiated.

### Match history
- Completed matches newest-first: scoreline, per-game breakdown for series,
  **ELO change** (hover for the exact winner/loser deltas), an `uploaded` tag,
  and a ⚡ `adjusted` flag when the commissioner changed scoring config before it.
- **Delete a match** (commissioner) — removes it and **recomputes the season** so
  ratings come out exactly as if it never happened.

### ELO engine (server-side, at match completion)
- Standard logistic expected score (base 400). Strong-beats-weak = small gain,
  upset = big swing.
- **Phased K-factor** — stable in week 1 (`k_stable`), swingier from week 2
  (`k_swingy`), cutover at `swingy_after_days`; `k_override` hard-overrides.
- **Margin of victory** nudges ratings (an 11-2 blowout moves more than an 11-9
  grind), weighted and capped to stay sane.
- Rating floor (1000 in the first season). ELO is applied **once per match**,
  never client-side.

### Seasons
- Commissioner can **start a season**, **configure** all ELO levers, and **end a
  season** (which archives stats and auto-retires all players).
- A full reset of ELO / W-L / rank on each new season; prior seasons stay
  queryable (their stat rows *are* the archive). Scoring-config changes are logged.

### Tournaments
- Single-elimination, seeded **by ELO** (reorderable) or **manually**.
- Live bracket with byes and auto-advancement; an official taps **Play** to run a
  matchup. Tournament games are **ELO-neutral** (they don't touch league ratings).
- Double-elim / round-robin are wired in the schema for later, switched off.

### Roles (no logins — access codes)
- **viewer** — reads everything, no code.
- **official** — runs matches: start/cancel, all in-match scoring, and tournament
  bracket play.
- **commissioner** — everything else: roster, seasons, codes, tournament setup,
  and match deletion.
- Enforced server-side: RLS allows public reads but **no direct writes** — every
  mutation goes through a code-checked `SECURITY DEFINER` rpc. UI gating is just
  cosmetic.

---

## Seasons model — Season 0 first

**Season 0 is the shakeout season.** It runs the full flow with real players to
validate scoring, the officiate dashboard, and the ELO spread before anything
counts. Once the mechanics feel right, **Season 1** starts fresh (full reset +
archive of Season 0) as the first "official" season — players get 3–5 games each
to let ratings spread out from the 1000 start.

Switching seasons is a commissioner action in the **Seasons** page; ending a
season archives its stats and retires the roster automatically.

---

## Backend (Supabase)

The schema and all write rpcs live in the repo as ordered SQL files — run them in
the Supabase SQL Editor in order (they're re-runnable):

| File | What it sets up |
|------|------------------|
| `01_schema.sql` | Tables, enums, views, RLS (read-all / deny-write), access-code helpers |
| `02_setup.sql` | `whoami` / `get_public_settings`, config rpcs, Realtime publication |
| `03_match_engine.sql` | start/score/complete/cancel a match; ELO at completion |
| `04_players.sql` | add / retire players (commissioner) |
| `05_seasons.sql` | season config + start/end season, config-change log |
| `06_officiate.sql` | flip a point, flip the first server |
| `07_tournaments.sql` | create / seed / start tournaments, bracket play |
| `08_admin.sql` | delete a match + recompute a season |

`02_supabase_setup.md` is the click-by-click runbook (create project, run SQL,
set access codes, add players, activate a season, smoke test).

---

## Local dev
```bash
npm install
cp .env.example .env      # fill in your Supabase URL + anon key
npm run dev               # http://localhost:3000
```

## Deploy to GitHub Pages
Already wired and deploying via `.github/workflows/deploy.yml` on every push to
`main`. To stand up your own copy:

1. Set `app.baseURL` in `nuxt.config.ts` to **`/<your-repo-name>/`** (this repo
   uses `/pongRank/`). For a custom domain or `username.github.io` root, use `/`.
2. Repo **Settings → Pages → Source: GitHub Actions**.
3. Repo **Settings → Secrets and variables → Actions → Variables tab** (Variables,
   not Secrets — the anon key is public by design and is needed at build time):
   - `NUXT_PUBLIC_SUPABASE_URL` = your Project URL
   - `NUXT_PUBLIC_SUPABASE_KEY` = your anon public key
4. Push to `main`; the site lands at `https://<username>.github.io/<repo>/`.

## Notes
- Only ever use the **anon public** key in the frontend. The `service_role` key
  must never touch it — RLS + code-checked rpcs are what keep writes safe.
- If pages 404 on refresh, confirm `baseURL` matches the repo name exactly.

# Supabase Setup Runbook — Ping Pong League (Step 2)

Follow these once. ~15 minutes. You'll come out with a live database, Realtime on, codes set, and Season 1 running. Keep the two values from Step A handy — the Nuxt app needs them later.

## A. Create the project
1. Go to supabase.com, sign in, **New project**.
2. Name it (e.g. `pingpong-league`), pick a region near you, set a database password (save it).
3. Wait for it to finish provisioning.
4. Open **Project Settings → API** and copy two values — you'll paste these into the Nuxt app in a later step:
   - **Project URL** (looks like `https://xxxx.supabase.co`)
   - **anon public** key (the long `eyJ...` string — this is safe to ship in the browser; it's meant to be public, which is why our RLS blocks writes)

## B. Load the schema
1. Left sidebar → **SQL Editor → New query**.
2. Paste the entire contents of **`01_schema.sql`**, click **Run**. Expect "Success, no rows returned."
3. New query again, paste **`02_setup.sql`**, **Run**. Same success message.

If a statement errors, run the files top-to-bottom in order (01 then 02) in a fresh query — they depend on each other.

## C. Confirm Realtime is on
1. Sidebar → **Database → Publications → `supabase_realtime`**.
2. You should see `matches`, `games`, `points`, `queue`, `player_season_stats`, `tournament_matches`, and `app_settings` listed. (Step 2 SQL added them; this is just a visual check.)

## D. Set your real access codes
The schema ships with placeholder codes. Change them now. SQL Editor → New query, fill in your own values, **Run**:

```sql
select set_access_codes(
  'change-me-commish',     -- the CURRENT commissioner code (placeholder on first run)
  'YOUR-NEW-COMMISH-CODE',  -- pick something only you know
  'YOUR-NEW-OFFICIAL-CODE'  -- share this with officials
);
```

From now on, the commissioner code is the master key. Anyone with the official code can log scores; anyone with neither is a viewer.

## E. Add players and start Season 1
Replace codes/names with yours. **Run**:

```sql
-- create the season (full reset, ELO floor 1000 for season 1)
select create_season('YOUR-NEW-COMMISH-CODE', 'Season 1',
                     '2026-06-15', '2026-06-29', 1000);

-- add players (run for each; pool up to ~20)
select add_player('YOUR-NEW-COMMISH-CODE', 'Alice');
select add_player('YOUR-NEW-COMMISH-CODE', 'Ben');
-- ...repeat...
```

Then activate the season — this flips it live and creates everyone's 1000-rated stat row:

```sql
-- grab the season id
select id, name from seasons where name = 'Season 1';

-- activate it (paste the id)
select activate_season('YOUR-NEW-COMMISH-CODE', 'PASTE-SEASON-ID-HERE');
```

> Order matters slightly: players added **before** activation are picked up automatically on activation; players added **after** activation get a stat row immediately via `add_player`. Either works.

## F. Smoke test
SQL Editor:

```sql
select * from v_current_standings;   -- every player at 1000, ranked
select whoami('YOUR-NEW-COMMISH-CODE');  -- should return 'commissioner'
select whoami('literally-anything');     -- should return 'viewer'
select * from get_public_settings();     -- active_season_id should be set
```

If standings list your players at 1000 and `whoami` returns the right roles, the backend is done.

## What you should NOT do
- Don't paste the **service_role** key anywhere in the frontend. Only the **anon public** key goes in the browser.
- Don't re-add tables to the publication if they're already there — it errors harmlessly but isn't needed.

---

**Hand-off to Step 3:** keep your **Project URL** and **anon public key** ready. Step 3 scaffolds the Nuxt app and wires those two values in, then configures it to build static for GitHub Pages.

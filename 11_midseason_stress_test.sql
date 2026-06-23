-- =====================================================================
--  MID-SEASON STRESS TEST  (TEMPORARY — Season 0 fun, not official play)
-- =====================================================================
--  Cranks the back half of Season 0 into chaos mode to shake up the board:
--   * binary win/loss engine (margin_as_score = false) so EVERY loss costs a
--     top dog the full whack (margin-as-score shields close losses — the
--     opposite of what we want here)
--   * k_override = 160  (4x the swingy K of 40 → wins/losses swing ~4x harder)
--   * elo_floor = 500   (lots of downside room → big spread)
--   * one-time +100 "comeback buffer" for anyone who's played and is under 1000
--
--  FORWARD-ONLY: no recompute. Past matches keep their deltas; the wild K/floor
--  apply to matches completed from here on. The leaderboard becomes a hybrid —
--  which is exactly a mid-season rule change.
--
--  REVERT for official play (e.g. Season 1) — restore the 09 model:
--    update seasons set margin_as_score = true, k_override = null, elo_floor = 900
--    where id = (select active_season_id from app_settings where id = 1);
--
--  Run in the Supabase SQL editor. Sections 1 & 3 are re-runnable;
--  SECTION 2 (the +100 buffer) MUST RUN EXACTLY ONCE.
-- =====================================================================

-- 1) Engine → binary big-K chaos on the active season
update seasons set
  margin_as_score = false,
  k_override      = 160,
  elo_floor       = 500
where id = (select active_season_id from app_settings where id = 1);

-- 2) +100 comeback buffer — ⚠ RUN ONCE. Players who've logged a match and sit
--    under 1000 (benched 0-game players are excluded by matches_played > 0).
update player_season_stats set elo = elo + 100, updated_at = now()
where season_id = (select active_season_id from app_settings where id = 1)
  and matches_played > 0
  and elo < 1000;

-- 3) Announce it on the match-log / leaderboard banner, linking the full writeup
update app_settings set
  commissioner_note =
    '📣 Season 0.75 update — midseason titles are out, and the second half goes WILD: wins & losses swing 4× harder, the floor drops to 500, and anyone under 1000 gets a +100 comeback buffer. Top dogs, watch your back — tap Details for the full rundown.',
  commissioner_note_url =
    'https://github.com/arnoldalleviate/pongRank/blob/dev/docs/season-0.75-update.md'
where id = 1;

-- =====================================================================
--  END — the wackiness has begun. Revert with the block in the header above.
-- =====================================================================

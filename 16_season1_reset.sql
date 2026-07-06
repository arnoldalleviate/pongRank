-- =====================================================================
--  SEASON 1 RESET → "Admiration"   (run AFTER the Season-0 tournament finishes)
-- =====================================================================
--  Archives Season 0 (freezes its final standings = the permanent record) and
--  starts everyone fresh on the official margin-as-score model.
--    base 2000 · floor 1000 · K 20 (wk1) / 40 (wk2+) @ 3d · margin-as-score
--
--  ⚠ Run ONLY after crowning the tournament champion — activating Season 1
--    changes the active season, which hides the Season-0 tournament from the UI.
--  ⚠ Retire any players who've left BEFORE running this, or they'll get a fresh
--    2000 row: update players set is_active=false where name in (...);
-- =====================================================================

-- 1) create Season 1 with the official model + new base / floor / K
insert into seasons
  (name, status, start_date, start_rating, elo_floor,
   k_stable, k_swingy, swingy_after_days, k_override,
   margin_as_score, decisiveness_full, series_k_mult)
values
  ('Admiration', 'upcoming', current_date, 2000, 1000,
   20, 40, 3, null,
   true, 0.5, 2);

-- 2) activate it → archives Season 0, creates fresh 2000-rated rows for active players
--    replace <commissioner_code> with your code
select activate_season('<commissioner_code>',
  (select id from seasons where name = 'Admiration' order by created_at desc limit 1));

-- 3) launch banner (leaderboard + match log)
update app_settings set
  commissioner_note = '🎉 Season 1: Admiration is live — everyone resets to 2000 and the real scoring is on (close games barely move, statement wins count). Season 0''s champions are in the books. Fresh ladder — let''s play.',
  commissioner_note_url = 'https://github.com/arnoldalleviate/pongRank/blob/dev/docs/season-0-finale.md'
where id = 1;

-- =====================================================================
--  END — Season 1 open. The leaderboard auto-drops the Season-0 recap/titles/
--  flair/tournament banner (they're gated to the "Season 0" name).
-- =====================================================================

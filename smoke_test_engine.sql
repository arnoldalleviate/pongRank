-- =====================================================================
--  ELO ENGINE SMOKE TEST  —  SAFE: wrapped in a transaction that ROLLS BACK
-- =====================================================================
--  Plays a real match through the rpcs and shows the resulting standings,
--  then discards EVERYTHING. Your live data is left untouched.
--
--  HOW TO RUN (Supabase SQL Editor):
--    1. Paste your COMMISSIONER code into v_code below (replace the
--       placeholder). It's needed because start_match/complete_match are
--       commissioner/official-gated — same as the app.
--    2. Run the whole script. Read the result grid at the end.
--    3. The final ROLLBACK throws the test match away. Nothing persists.
--
--  SCENARIO: Alice (1000) beats Ben (1000) 11–2, Quick match.
--  EXPECTED (today is pre-season => STABLE phase: K=20, ratio MoV, weight .5):
--    mult = 1 + 0.5 * (9/13) ≈ 1.346
--    ΔAlice = round(20 * 1.346 * (1 - 0.5)) = +13   -> Alice 1013
--    ΔBen   = -13  -> 987, BUT Season-1 floor = 1000, so Ben stays 1000.
--  So the grid should show:  Alice 1013 (1–0),  Ben 1000 (0–1).
--  (If Ben showed 987, the floor would be broken; if Alice ≠ 1013, the
--   K/MoV math would be off.)
-- =====================================================================

begin;

do $$
declare
  v_code  text := 'PASTE-YOUR-COMMISSIONER-CODE-HERE';
  v_alice uuid;
  v_ben   uuid;
  v_match matches;
  v_game  games;
  i       int;
begin
  select id into v_alice from players where name = 'Alice';
  select id into v_ben   from players where name = 'Ben';
  if v_alice is null or v_ben is null then
    raise exception 'This test expects players named Alice and Ben — edit the names if yours differ';
  end if;

  -- commissioner starts the match (Alice = player_a, serves first)
  v_match := start_match(v_code, v_alice, v_ben, 'quick', v_alice);
  select * into v_game from games where match_id = v_match.id and game_number = 1;

  -- official scores it to 11–2 (Ben gets 2 early, Alice runs to 11)
  perform add_point(v_code, v_game.id, v_ben,   v_ben);
  perform add_point(v_code, v_game.id, v_alice, v_ben);
  for i in 1..11 loop
    perform add_point(v_code, v_game.id, v_alice, v_alice);
  end loop;
  -- (the 11th Alice point closes the game at 11–2)

  -- apply ELO
  perform complete_match(v_code, v_match.id);
end $$;

-- post-match standings, inside the transaction (about to be rolled back)
select rank, name, elo, wins, losses, games_won, games_lost,
       points_for, points_against, current_streak
from v_current_standings
order by rank;

rollback;
-- =====================================================================
--  END — everything above was discarded by ROLLBACK
-- =====================================================================

-- =====================================================================
--  ADMIN — delete a match + recompute  (Step 8.5 backend, commissioner)
-- =====================================================================
--  Run AFTER 01-07, in the Supabase SQL Editor. Re-runnable.
--
--  recompute_season: reset every player's season stats and replay all
--  completed LEAGUE matches in chronological order (tournament games are
--  ELO-neutral, so they're skipped), re-deriving ELO / W-L / games / points /
--  streaks / peak exactly from the match log. Uses each match's completed_at
--  for the stable/swingy phase, so it reproduces what complete_match computed.
--
--  delete_match: remove a completed (or cancelled) LEAGUE match + its games/
--  points, then recompute — so a deletion correctly un-does the ratings it
--  produced, no matter where in the season it sits.
-- =====================================================================

create or replace function recompute_season(p_code text, p_season_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_season seasons;
  m matches;
  v_a_games int; v_b_games int; v_needed int; v_a_pf int; v_a_pa int;
  v_winner uuid; v_is_swingy boolean; v_k int; v_formula mov_formula;
  v_mult numeric; v_ea numeric;
  v_elo_a int; v_elo_b int; v_new_a int; v_new_b int; v_da int; v_db int; v_floor int;
begin
  perform require_role(p_code, 'commissioner');
  select * into v_season from seasons where id = p_season_id;
  if v_season.id is null then raise exception 'Season not found'; end if;

  -- reset every player's stats for this season
  update player_season_stats set
    elo = v_season.start_rating, peak_elo = v_season.start_rating,
    wins = 0, losses = 0, games_won = 0, games_lost = 0,
    points_for = 0, points_against = 0, current_streak = 0, best_streak = 0,
    matches_played = 0, final_rank = null, updated_at = now()
  where season_id = p_season_id;

  -- replay completed league matches in order
  for m in
    select * from matches
    where season_id = p_season_id and status = 'completed' and tournament_match_id is null
    order by completed_at nulls last, created_at
  loop
    select count(*) filter (where winner_id = m.player_a),
           count(*) filter (where winner_id = m.player_b),
           coalesce(sum(score_a), 0), coalesce(sum(score_b), 0)
      into v_a_games, v_b_games, v_a_pf, v_a_pa
    from games where match_id = m.id and status = 'completed';

    v_needed := case m.type when 'series' then 2 else 1 end;
    if v_a_games < v_needed and v_b_games < v_needed then continue; end if;
    v_winner := case when v_a_games >= v_needed then m.player_a else m.player_b end;

    select elo into v_elo_a from player_season_stats where season_id = p_season_id and player_id = m.player_a;
    select elo into v_elo_b from player_season_stats where season_id = p_season_id and player_id = m.player_b;
    if v_elo_a is null or v_elo_b is null then continue; end if;

    v_is_swingy := v_season.start_date is not null
                   and (m.completed_at::date - v_season.start_date) >= v_season.swingy_after_days;
    v_k := coalesce(v_season.k_override, case when v_is_swingy then v_season.k_swingy else v_season.k_stable end);
    v_formula := case when v_is_swingy then v_season.mov_formula_swingy else v_season.mov_formula_stable end;
    v_mult := mov_multiplier(v_a_pf, v_a_pa, v_season.mov_enabled, v_season.mov_weight, v_season.mov_cap, v_formula);
    v_ea := elo_expected(v_elo_a, v_elo_b);

    v_da := round(v_k * v_mult * ((case when v_winner = m.player_a then 1 else 0 end) - v_ea))::int;
    v_db := round(v_k * v_mult * ((case when v_winner = m.player_b then 1 else 0 end) - (1 - v_ea)))::int;
    v_floor := v_season.elo_floor;
    v_new_a := v_elo_a + v_da; v_new_b := v_elo_b + v_db;
    if v_floor is not null then v_new_a := greatest(v_new_a, v_floor); v_new_b := greatest(v_new_b, v_floor); end if;
    v_da := v_new_a - v_elo_a; v_db := v_new_b - v_elo_b;

    update player_season_stats set
      elo = v_new_a, peak_elo = greatest(peak_elo, v_new_a),
      wins   = wins   + (case when v_winner = m.player_a then 1 else 0 end),
      losses = losses + (case when v_winner = m.player_a then 0 else 1 end),
      games_won = games_won + v_a_games, games_lost = games_lost + v_b_games,
      points_for = points_for + v_a_pf, points_against = points_against + v_a_pa,
      current_streak = case when v_winner = m.player_a
                            then (case when current_streak >= 0 then current_streak + 1 else 1 end)
                            else (case when current_streak <= 0 then current_streak - 1 else -1 end) end,
      best_streak = greatest(best_streak, case when v_winner = m.player_a
                            then (case when current_streak >= 0 then current_streak + 1 else 1 end) else best_streak end),
      matches_played = matches_played + 1, updated_at = now()
    where season_id = p_season_id and player_id = m.player_a;

    update player_season_stats set
      elo = v_new_b, peak_elo = greatest(peak_elo, v_new_b),
      wins   = wins   + (case when v_winner = m.player_b then 1 else 0 end),
      losses = losses + (case when v_winner = m.player_b then 0 else 1 end),
      games_won = games_won + v_b_games, games_lost = games_lost + v_a_games,
      points_for = points_for + v_a_pa, points_against = points_against + v_a_pf,
      current_streak = case when v_winner = m.player_b
                            then (case when current_streak >= 0 then current_streak + 1 else 1 end)
                            else (case when current_streak <= 0 then current_streak - 1 else -1 end) end,
      best_streak = greatest(best_streak, case when v_winner = m.player_b
                            then (case when current_streak >= 0 then current_streak + 1 else 1 end) else best_streak end),
      matches_played = matches_played + 1, updated_at = now()
    where season_id = p_season_id and player_id = m.player_b;

    update matches set
      a_elo_before = v_elo_a, a_elo_after = v_new_a, a_elo_change = v_da,
      b_elo_before = v_elo_b, b_elo_after = v_new_b, b_elo_change = v_db
    where id = m.id;
  end loop;
end; $$;

-- ---------------------------------------------------------------------
-- delete a match (commissioner) — league matches only; not in-progress
-- ---------------------------------------------------------------------
create or replace function delete_match(p_code text, p_match_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_match matches;
begin
  perform require_role(p_code, 'commissioner');
  select * into v_match from matches where id = p_match_id;
  if v_match.id is null then raise exception 'Match not found'; end if;
  if v_match.status = 'in_progress' then raise exception 'Cancel the in-progress match instead of deleting it'; end if;
  if v_match.tournament_match_id is not null then raise exception 'Tournament matches cannot be deleted here'; end if;

  delete from matches where id = p_match_id;          -- cascades games + points
  perform recompute_season(p_code, v_match.season_id); -- un-do its rating impact
end; $$;

-- =====================================================================
--  END OF ADMIN BACKEND
-- =====================================================================

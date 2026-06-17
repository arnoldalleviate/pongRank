-- =====================================================================
--  MARGIN-AS-SCORE + SERIES WEIGHTING + FLOOR TUNING   (ELO refinement)
-- =====================================================================
--  Player feedback (2026-06-17): a 2-1 loss should sting less than a 2-0;
--  a coin-flip match (e.g. 1-1 into an overtime decider) is "fair" and
--  should barely move ratings; a *dominant* series should outweigh a single
--  game. Performance is examined in EVERY match, not just the win/loss.
--
--  MODEL (all per-season levers — tune live in Season 0):
--   * margin_as_score = true -> the RESULT is a continuum, not 1/0:
--        margin       = (winnerPts - loserPts) / totalPts      (total points, whole match)
--        decisiveness = clamp( margin / decisiveness_full , 0 .. 1 )
--        S_winner     = 0.5 + 0.5 * decisiveness   (floored at 0.5 -> winning never costs rating)
--        delta        = K * (S - Expected)
--     Coin-flip -> S~0.5 -> ~no shift.  Blowout -> S~1 -> full shift.
--     (Won the match on fewer total points? margin<0 -> decisiveness 0 -> a "fair" win.)
--   * series_k_mult  -> series carry more weight (default 2.0: a dominant
--                       series moves ~2x a dominant single game).
--   * decisiveness_full -> the point-margin ratio that counts as "total
--                       domination" (S=1.0). Default 0.5. Lower = more swingy.
--   * margin_as_score = false -> legacy binary win/loss + MoV multiplier (unchanged).
--
--  Also lowers the active season's ELO floor 1000 -> 900 so players who would
--  otherwise be pinned at the 1000 start can sink — which stops wins against
--  floor-capped players from being over-rewarded.
--
--  Run AFTER 01-08 in the Supabase SQL Editor. Re-runnable. After running,
--  call recompute_season(<commish_code>, <active_season_id>) to re-derive
--  existing matches under the new model.
-- =====================================================================

alter table seasons add column if not exists margin_as_score  boolean not null default true;
alter table seasons add column if not exists decisiveness_full numeric not null default 0.5;
alter table seasons add column if not exists series_k_mult     numeric not null default 2.0;

-- S for the MATCH WINNER (0.5 .. 1.0) from the total-point margin.
-- A negative or zero margin floors to 0.5 (a "fair" win -> minimal shift).
create or replace function decisiveness_score(p_win_pts int, p_lose_pts int, p_full numeric)
returns numeric language sql immutable as $$
  select 0.5 + 0.5 * greatest(0.0, least(1.0, coalesce(
    ((p_win_pts - p_lose_pts)::numeric / nullif(p_win_pts + p_lose_pts, 0)) / nullif(p_full, 0)
  , 0.0)));
$$;

-- ---------------------------------------------------------------------
-- complete_match — now scores by margin (see model above); legacy MoV
-- multiplier preserved for seasons with margin_as_score = false.
-- ---------------------------------------------------------------------
create or replace function complete_match(p_code text, p_match_id uuid)
returns matches
language plpgsql security definer set search_path = public as $$
declare
  v_match     matches;
  v_season    seasons;
  v_a_games   int;
  v_b_games   int;
  v_needed    int;
  v_a_pf      int;   -- player_a points for (= sum score_a)
  v_a_pa      int;   -- player_a points against (= sum score_b)
  v_winner    uuid;
  v_is_swingy boolean;
  v_k         int;
  v_formula   mov_formula;
  v_mult      numeric;
  v_ea        numeric;
  v_win_pts   int;   v_lose_pts int;   v_sw numeric;   -- margin-as-score
  v_elo_a     int;   v_elo_b int;   -- before
  v_new_a     int;   v_new_b int;   -- after (floored)
  v_da        int;   v_db    int;   -- applied change
  v_floor     int;
begin
  perform require_role(p_code, 'official');

  select * into v_match from matches where id = p_match_id;
  if v_match.id is null then raise exception 'Match not found'; end if;
  if v_match.status <> 'in_progress' then
    raise exception 'Match is not in progress (already completed/cancelled)';
  end if;

  select * into v_season from seasons where id = v_match.season_id;

  select count(*) filter (where winner_id = v_match.player_a),
         count(*) filter (where winner_id = v_match.player_b),
         coalesce(sum(score_a), 0), coalesce(sum(score_b), 0)
    into v_a_games, v_b_games, v_a_pf, v_a_pa
  from games where match_id = p_match_id and status = 'completed';

  v_needed := case v_match.type when 'series' then 2 else 1 end;
  if v_a_games < v_needed and v_b_games < v_needed then
    raise exception 'Match is not decided yet';
  end if;
  v_winner := case when v_a_games >= v_needed then v_match.player_a else v_match.player_b end;

  select elo into v_elo_a from player_season_stats
   where season_id = v_match.season_id and player_id = v_match.player_a;
  select elo into v_elo_b from player_season_stats
   where season_id = v_match.season_id and player_id = v_match.player_b;
  if v_elo_a is null or v_elo_b is null then
    raise exception 'Missing season stat rows for one of the players';
  end if;

  -- phase: week 1 stable, week 2+ swingy, flip at swingy_after_days
  v_is_swingy := v_season.start_date is not null
                 and (current_date - v_season.start_date) >= v_season.swingy_after_days;
  v_k := coalesce(v_season.k_override,
                  case when v_is_swingy then v_season.k_swingy else v_season.k_stable end);
  v_ea := elo_expected(v_elo_a, v_elo_b);

  if v_season.margin_as_score then
    -- series carry more weight (more games examined)
    if v_match.type = 'series' then v_k := round(v_k * v_season.series_k_mult)::int; end if;
    v_win_pts  := case when v_winner = v_match.player_a then v_a_pf else v_a_pa end;
    v_lose_pts := case when v_winner = v_match.player_a then v_a_pa else v_a_pf end;
    v_sw := decisiveness_score(v_win_pts, v_lose_pts, v_season.decisiveness_full);  -- winner's S
    if v_winner = v_match.player_a then
      v_da := round(v_k * (v_sw - v_ea))::int;
      v_db := round(v_k * ((1 - v_sw) - (1 - v_ea)))::int;
    else
      v_da := round(v_k * ((1 - v_sw) - v_ea))::int;
      v_db := round(v_k * (v_sw - (1 - v_ea)))::int;
    end if;
  else
    -- legacy: binary win/loss scaled by the MoV multiplier
    v_formula := case when v_is_swingy then v_season.mov_formula_swingy else v_season.mov_formula_stable end;
    v_mult := mov_multiplier(v_a_pf, v_a_pa, v_season.mov_enabled,
                             v_season.mov_weight, v_season.mov_cap, v_formula);
    v_da := round(v_k * v_mult * ((case when v_winner = v_match.player_a then 1 else 0 end) - v_ea))::int;
    v_db := round(v_k * v_mult * ((case when v_winner = v_match.player_b then 1 else 0 end) - (1 - v_ea)))::int;
  end if;

  v_floor := v_season.elo_floor;
  v_new_a := v_elo_a + v_da;
  v_new_b := v_elo_b + v_db;
  if v_floor is not null then
    v_new_a := greatest(v_new_a, v_floor);
    v_new_b := greatest(v_new_b, v_floor);
  end if;
  v_da := v_new_a - v_elo_a;   -- actual applied change after floor
  v_db := v_new_b - v_elo_b;

  -- player A
  update player_season_stats set
    elo = v_new_a,
    peak_elo = greatest(peak_elo, v_new_a),
    wins   = wins   + (case when v_winner = v_match.player_a then 1 else 0 end),
    losses = losses + (case when v_winner = v_match.player_a then 0 else 1 end),
    games_won  = games_won  + v_a_games,
    games_lost = games_lost + v_b_games,
    points_for     = points_for     + v_a_pf,
    points_against = points_against + v_a_pa,
    current_streak = case when v_winner = v_match.player_a
                          then (case when current_streak >= 0 then current_streak + 1 else 1 end)
                          else (case when current_streak <= 0 then current_streak - 1 else -1 end) end,
    best_streak = greatest(best_streak,
                    case when v_winner = v_match.player_a
                         then (case when current_streak >= 0 then current_streak + 1 else 1 end)
                         else best_streak end),
    matches_played = matches_played + 1,
    updated_at = now()
  where season_id = v_match.season_id and player_id = v_match.player_a;

  -- player B
  update player_season_stats set
    elo = v_new_b,
    peak_elo = greatest(peak_elo, v_new_b),
    wins   = wins   + (case when v_winner = v_match.player_b then 1 else 0 end),
    losses = losses + (case when v_winner = v_match.player_b then 0 else 1 end),
    games_won  = games_won  + v_b_games,
    games_lost = games_lost + v_a_games,
    points_for     = points_for     + v_a_pa,
    points_against = points_against + v_a_pf,
    current_streak = case when v_winner = v_match.player_b
                          then (case when current_streak >= 0 then current_streak + 1 else 1 end)
                          else (case when current_streak <= 0 then current_streak - 1 else -1 end) end,
    best_streak = greatest(best_streak,
                    case when v_winner = v_match.player_b
                         then (case when current_streak >= 0 then current_streak + 1 else 1 end)
                         else best_streak end),
    matches_played = matches_played + 1,
    updated_at = now()
  where season_id = v_match.season_id and player_id = v_match.player_b;

  update matches set
    status = 'completed', completed_at = now(), winner_id = v_winner,
    a_elo_before = v_elo_a, a_elo_after = v_new_a, a_elo_change = v_da,
    b_elo_before = v_elo_b, b_elo_after = v_new_b, b_elo_change = v_db
  where id = p_match_id
  returning * into v_match;

  update app_settings
     set current_match_id = null, table_state = 'open', updated_at = now()
   where id = 1 and current_match_id = p_match_id;

  return v_match;
end; $$;

-- ---------------------------------------------------------------------
-- recompute_season — replay completed league matches under the SAME
-- model (margin-as-score + series weighting), so deletes/edits and a
-- scoring change re-derive ratings exactly.
-- ---------------------------------------------------------------------
create or replace function recompute_season(p_code text, p_season_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_season seasons;
  m matches;
  v_a_games int; v_b_games int; v_needed int; v_a_pf int; v_a_pa int;
  v_winner uuid; v_is_swingy boolean; v_k int; v_formula mov_formula;
  v_mult numeric; v_ea numeric;
  v_win_pts int; v_lose_pts int; v_sw numeric;
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
    v_ea := elo_expected(v_elo_a, v_elo_b);

    if v_season.margin_as_score then
      if m.type = 'series' then v_k := round(v_k * v_season.series_k_mult)::int; end if;
      v_win_pts  := case when v_winner = m.player_a then v_a_pf else v_a_pa end;
      v_lose_pts := case when v_winner = m.player_a then v_a_pa else v_a_pf end;
      v_sw := decisiveness_score(v_win_pts, v_lose_pts, v_season.decisiveness_full);
      if v_winner = m.player_a then
        v_da := round(v_k * (v_sw - v_ea))::int;
        v_db := round(v_k * ((1 - v_sw) - (1 - v_ea)))::int;
      else
        v_da := round(v_k * ((1 - v_sw) - v_ea))::int;
        v_db := round(v_k * (v_sw - (1 - v_ea)))::int;
      end if;
    else
      v_formula := case when v_is_swingy then v_season.mov_formula_swingy else v_season.mov_formula_stable end;
      v_mult := mov_multiplier(v_a_pf, v_a_pa, v_season.mov_enabled, v_season.mov_weight, v_season.mov_cap, v_formula);
      v_da := round(v_k * v_mult * ((case when v_winner = m.player_a then 1 else 0 end) - v_ea))::int;
      v_db := round(v_k * v_mult * ((case when v_winner = m.player_b then 1 else 0 end) - (1 - v_ea)))::int;
    end if;

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
-- Tuning: lower the active season's ELO floor 1000 -> 900 (see header).
-- Adjust the value as desired; do not re-run this file if you've since
-- changed the floor elsewhere, or it will reset to 900.
-- ---------------------------------------------------------------------
update seasons set elo_floor = 900
 where id = (select active_season_id from app_settings where id = 1);

-- =====================================================================
--  END — after running, recompute the active season to apply retroactively:
--    select recompute_season('<commissioner_code>', '<active_season_id>');
-- =====================================================================

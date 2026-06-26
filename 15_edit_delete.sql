-- =====================================================================
--  LOCAL EDIT / DELETE — no full recompute  (mitigates delete breakage)
-- =====================================================================
--  ELO is path-dependent, so a perfect mid-history correction needs a full
--  replay (recompute_season). These do a LOCAL fix instead — point-conserving
--  and correct at the match's own moment — without replaying everything (which
--  was wiping manual ratings + going degenerate under the chaos K).
--
--   * match_elo_delta(...) — the shared engine delta (mirrors complete_match:
--     phased/override K, margin-as-score or legacy MoV, floor) so edit reuses
--     the exact live formula.
--   * delete_match — REVERSES the match's stored delta (gives the ELO back) +
--     decrements W/L/games/points. No recompute.
--   * edit_match — correct a match's scores in place: recompute its delta from
--     the match's OWN stored pre-ratings (a_elo_before) and apply only the
--     DIFFERENCE to current ratings. No resubmit, no replay.
--
--  Caveat: matches played AFTER the edited/deleted one are NOT replayed, so
--  later absolute ratings drift slightly from a true recompute; streak/peak are
--  left as-is. Fine for a casual league; resets clean at Season 1.
--
--  Run AFTER 01-09. Re-runnable.
-- =====================================================================

-- shared engine delta (after floor), given the BEFORE ratings + game tallies
create or replace function match_elo_delta(
  p_season_id uuid, p_elo_a int, p_elo_b int,
  p_a_games int, p_b_games int, p_a_pf int, p_a_pa int,
  p_type match_type, p_when date
) returns table(da int, db int)
language plpgsql security definer set search_path = public as $$
declare
  v_season seasons; v_is_swingy boolean; v_k int; v_formula mov_formula; v_mult numeric; v_ea numeric;
  v_winner_is_a boolean; v_needed int; v_win_pts int; v_lose_pts int; v_sw numeric;
  v_new_a int; v_new_b int; v_floor int;
begin
  select * into v_season from seasons where id = p_season_id;
  v_needed := case p_type when 'series' then 2 else 1 end;
  v_winner_is_a := p_a_games >= v_needed;
  v_is_swingy := v_season.start_date is not null and (p_when - v_season.start_date) >= v_season.swingy_after_days;
  v_k := coalesce(v_season.k_override, case when v_is_swingy then v_season.k_swingy else v_season.k_stable end);
  v_ea := elo_expected(p_elo_a, p_elo_b);

  if v_season.margin_as_score then
    if p_type = 'series' then v_k := round(v_k * v_season.series_k_mult)::int; end if;
    if v_winner_is_a then v_win_pts := p_a_pf; v_lose_pts := p_a_pa; else v_win_pts := p_a_pa; v_lose_pts := p_a_pf; end if;
    v_sw := decisiveness_score(v_win_pts, v_lose_pts, v_season.decisiveness_full);
    if v_winner_is_a then
      da := round(v_k * (v_sw - v_ea))::int;       db := round(v_k * ((1 - v_sw) - (1 - v_ea)))::int;
    else
      da := round(v_k * ((1 - v_sw) - v_ea))::int; db := round(v_k * (v_sw - (1 - v_ea)))::int;
    end if;
  else
    v_formula := case when v_is_swingy then v_season.mov_formula_swingy else v_season.mov_formula_stable end;
    v_mult := mov_multiplier(p_a_pf, p_a_pa, v_season.mov_enabled, v_season.mov_weight, v_season.mov_cap, v_formula);
    da := round(v_k * v_mult * ((case when v_winner_is_a then 1 else 0 end) - v_ea))::int;
    db := round(v_k * v_mult * ((case when v_winner_is_a then 0 else 1 end) - (1 - v_ea)))::int;
  end if;

  v_floor := v_season.elo_floor;
  v_new_a := p_elo_a + da; v_new_b := p_elo_b + db;
  if v_floor is not null then v_new_a := greatest(v_new_a, v_floor); v_new_b := greatest(v_new_b, v_floor); end if;
  da := v_new_a - p_elo_a; db := v_new_b - p_elo_b;
  return next;
end; $$;

-- ---------------------------------------------------------------------
-- delete_match — local reverse (gives the ELO back), no recompute.
-- ---------------------------------------------------------------------
create or replace function delete_match(p_code text, p_match_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_m matches; v_a_games int; v_b_games int; v_a_pf int; v_a_pa int;
begin
  perform require_role(p_code, 'commissioner');
  select * into v_m from matches where id = p_match_id;
  if v_m.id is null then raise exception 'Match not found'; end if;
  if v_m.status = 'in_progress' then raise exception 'Cancel the in-progress match instead of deleting it'; end if;
  if v_m.tournament_match_id is not null then raise exception 'Tournament matches cannot be deleted here'; end if;

  if v_m.status = 'completed' and v_m.winner_id is not null then
    select count(*) filter (where winner_id = v_m.player_a), count(*) filter (where winner_id = v_m.player_b),
           coalesce(sum(score_a), 0), coalesce(sum(score_b), 0)
      into v_a_games, v_b_games, v_a_pf, v_a_pa
    from games where match_id = p_match_id and status = 'completed';

    update player_season_stats set
      elo = elo - coalesce(v_m.a_elo_change, 0),
      wins   = greatest(0, wins   - (case when v_m.winner_id = v_m.player_a then 1 else 0 end)),
      losses = greatest(0, losses - (case when v_m.winner_id = v_m.player_a then 0 else 1 end)),
      games_won = greatest(0, games_won - v_a_games), games_lost = greatest(0, games_lost - v_b_games),
      points_for = greatest(0, points_for - v_a_pf), points_against = greatest(0, points_against - v_a_pa),
      matches_played = greatest(0, matches_played - 1), updated_at = now()
    where season_id = v_m.season_id and player_id = v_m.player_a;

    update player_season_stats set
      elo = elo - coalesce(v_m.b_elo_change, 0),
      wins   = greatest(0, wins   - (case when v_m.winner_id = v_m.player_b then 1 else 0 end)),
      losses = greatest(0, losses - (case when v_m.winner_id = v_m.player_b then 0 else 1 end)),
      games_won = greatest(0, games_won - v_b_games), games_lost = greatest(0, games_lost - v_a_games),
      points_for = greatest(0, points_for - v_a_pa), points_against = greatest(0, points_against - v_a_pf),
      matches_played = greatest(0, matches_played - 1), updated_at = now()
    where season_id = v_m.season_id and player_id = v_m.player_b;
  end if;

  delete from matches where id = p_match_id;   -- cascades games + points
end; $$;

-- ---------------------------------------------------------------------
-- edit_match — correct a completed league match's scores in place.
-- ---------------------------------------------------------------------
create or replace function edit_match(p_code text, p_match_id uuid, p_games jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_m matches; v_needed int; v_winner uuid;
  v_oa int; v_ob int; v_opf int; v_opa int;            -- old tallies
  v_na int; v_nb int; v_npf int; v_npa int;            -- new tallies
  g jsonb; v_sa int; v_sb int; v_gnum int := 0; v_gwinner uuid; d record;
begin
  perform require_role(p_code, 'commissioner');
  select * into v_m from matches where id = p_match_id;
  if v_m.id is null then raise exception 'Match not found'; end if;
  if v_m.status <> 'completed' then raise exception 'Only a completed match can be edited'; end if;
  if v_m.tournament_match_id is not null then raise exception 'Edit tournament results via the bracket'; end if;
  if v_m.a_elo_before is null then raise exception 'No rating snapshot on this match to edit against'; end if;
  if p_games is null or jsonb_array_length(p_games) = 0 then raise exception 'No game scores provided'; end if;

  select count(*) filter (where winner_id = v_m.player_a), count(*) filter (where winner_id = v_m.player_b),
         coalesce(sum(score_a), 0), coalesce(sum(score_b), 0)
    into v_oa, v_ob, v_opf, v_opa
  from games where match_id = p_match_id and status = 'completed';

  -- replace games with the corrected scores
  delete from games where match_id = p_match_id;   -- cascades that match's points
  v_needed := case v_m.type when 'series' then 2 else 1 end;
  for g in select * from jsonb_array_elements(p_games) loop
    v_gnum := v_gnum + 1; v_sa := (g->>'a')::int; v_sb := (g->>'b')::int;
    if v_sa is null or v_sb is null or greatest(v_sa, v_sb) < 11 or abs(v_sa - v_sb) < 2 then
      raise exception 'Game % is not a legal result (%-%)', v_gnum, v_sa, v_sb;
    end if;
    v_gwinner := case when v_sa > v_sb then v_m.player_a else v_m.player_b end;
    insert into games (match_id, game_number, score_a, score_b, winner_id, status, completed_at)
    values (p_match_id, v_gnum, v_sa, v_sb, v_gwinner, 'completed', coalesce(v_m.completed_at, now()));
  end loop;

  select count(*) filter (where winner_id = v_m.player_a), count(*) filter (where winner_id = v_m.player_b),
         coalesce(sum(score_a), 0), coalesce(sum(score_b), 0)
    into v_na, v_nb, v_npf, v_npa
  from games where match_id = p_match_id and status = 'completed';
  if v_na < v_needed and v_nb < v_needed then raise exception 'Corrected games do not decide the match'; end if;
  v_winner := case when v_na >= v_needed then v_m.player_a else v_m.player_b end;

  -- new delta from the match's OWN pre-ratings (correct for that moment)
  select * into d from match_elo_delta(v_m.season_id, v_m.a_elo_before, v_m.b_elo_before,
                                       v_na, v_nb, v_npf, v_npa, v_m.type,
                                       coalesce(v_m.completed_at::date, current_date));

  -- player A: apply only the DIFFERENCE in ELO, and the net stat changes
  update player_season_stats set
    elo = elo + (d.da - coalesce(v_m.a_elo_change, 0)),
    wins   = greatest(0, wins   - (case when v_m.winner_id = v_m.player_a then 1 else 0 end) + (case when v_winner = v_m.player_a then 1 else 0 end)),
    losses = greatest(0, losses - (case when v_m.winner_id = v_m.player_a then 0 else 1 end) + (case when v_winner = v_m.player_a then 0 else 1 end)),
    games_won = greatest(0, games_won - v_oa + v_na), games_lost = greatest(0, games_lost - v_ob + v_nb),
    points_for = greatest(0, points_for - v_opf + v_npf), points_against = greatest(0, points_against - v_opa + v_npa),
    updated_at = now()
  where season_id = v_m.season_id and player_id = v_m.player_a;

  -- player B (mirror)
  update player_season_stats set
    elo = elo + (d.db - coalesce(v_m.b_elo_change, 0)),
    wins   = greatest(0, wins   - (case when v_m.winner_id = v_m.player_b then 1 else 0 end) + (case when v_winner = v_m.player_b then 1 else 0 end)),
    losses = greatest(0, losses - (case when v_m.winner_id = v_m.player_b then 0 else 1 end) + (case when v_winner = v_m.player_b then 0 else 1 end)),
    games_won = greatest(0, games_won - v_ob + v_nb), games_lost = greatest(0, games_lost - v_oa + v_na),
    points_for = greatest(0, points_for - v_opa + v_npa), points_against = greatest(0, points_against - v_opf + v_npf),
    updated_at = now()
  where season_id = v_m.season_id and player_id = v_m.player_b;

  -- rewrite the match snapshot + winner
  update matches set winner_id = v_winner,
    a_elo_after = v_m.a_elo_before + d.da, a_elo_change = d.da,
    b_elo_after = v_m.b_elo_before + d.db, b_elo_change = d.db
  where id = p_match_id;
end; $$;

-- =====================================================================
--  END — delete reverses locally; edit corrects in place. No replay.
-- =====================================================================

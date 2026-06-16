-- =====================================================================
--  PING PONG LEAGUE — MATCH & ELO ENGINE  (Step 4 backend)
-- =====================================================================
--  Run this AFTER 01_schema.sql and 02_setup.sql, in the Supabase SQL
--  Editor. Re-runnable (idempotent guards on the schema changes).
--
--  Adds the code-gated write-path rpcs that drive live scoring and the
--  ELO engine. Same security pattern as before: anon can't write tables
--  directly; every mutation goes through a SECURITY DEFINER function that
--  calls require_role() against the access codes.
--
--  Lifecycle (live):  start_match -> add_point* [-> start_game -> add_point*]
--                     -> complete_match            (undo: remove_last_point)
--  Lifecycle (upload):start_match -> submit_game_score* -> complete_match
--
--  ELO is applied ONCE, only inside complete_match (explicit finalize), so
--  undo works freely right up until the match is finalized.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. SCHEMA EXTENSIONS (phased margin-of-victory formula)
--    K already flips stable -> swingy at swingy_after_days; the MoV
--    formula flips at the SAME boundary: 'ratio' in the stable week,
--    'log' in the swingy week. mov_weight / mov_cap stay shared.
-- ---------------------------------------------------------------------
do $$ begin
  if not exists (select 1 from pg_type where typname = 'mov_formula') then
    create type mov_formula as enum ('ratio','log');
  end if;
end $$;

alter table seasons
  add column if not exists mov_formula_stable mov_formula not null default 'ratio',
  add column if not exists mov_formula_swingy mov_formula not null default 'log';

-- quick-upload games carry no point-by-point data, so serve info is unknown
alter table games alter column first_server_id drop not null;

-- a cancelled match records why (cancel flow: cancel -> reason -> confirm)
alter table matches add column if not exists cancel_reason text;

-- ---------------------------------------------------------------------
-- 1. PURE ELO MATH HELPERS (no table access; safe to be world-callable)
-- ---------------------------------------------------------------------
-- standard logistic expectation, base 400
create or replace function elo_expected(r_self int, r_opp int)
returns numeric language sql immutable as $$
  select 1.0 / (1.0 + pow(10.0, (r_opp - r_self) / 400.0));
$$;

-- margin-of-victory multiplier on K. pf/pa = match point totals (winner
-- perspective not required; uses the absolute margin so both players get
-- the same multiplier). greatest()/least() ignore NULLs, so a 0-0 guard
-- is unnecessary.
create or replace function mov_multiplier(
  pf int, pa int, enabled boolean, weight numeric, cap numeric, formula mov_formula
) returns numeric language sql immutable as $$
  select case
    when not enabled        then 1.0
    when formula = 'ratio'  then least(cap, greatest(1.0, 1.0 + weight * (abs(pf - pa)::numeric / nullif(pf + pa, 0))))
    when formula = 'log'    then least(cap, greatest(1.0, 1.0 + weight * ln(1.0 + abs(pf - pa))))
  end;
$$;

-- ---------------------------------------------------------------------
-- 2. START A MATCH  (commissioner)  -> creates the match + game 1
-- ---------------------------------------------------------------------
create or replace function start_match(
  p_code         text,
  p_player_a     uuid,
  p_player_b     uuid,
  p_type         match_type,
  p_first_server uuid,
  p_color_a      player_color default 'blue',
  p_color_b      player_color default 'yellow'
) returns matches
language plpgsql security definer set search_path = public as $$
declare
  v_season uuid;
  v_cur    uuid;
  v_start  int;
  v_match  matches;
begin
  perform require_role(p_code, 'commissioner');

  if p_player_a = p_player_b then
    raise exception 'A match needs two different players';
  end if;

  select active_season_id, current_match_id into v_season, v_cur
  from app_settings where id = 1;

  if v_season is null then
    raise exception 'No active season';
  end if;

  -- one live match at a time (single table)
  if v_cur is not null
     and exists (select 1 from matches where id = v_cur and status = 'in_progress') then
    raise exception 'A match is already in progress';
  end if;

  if not exists (select 1 from players where id = p_player_a and is_active)
     or not exists (select 1 from players where id = p_player_b and is_active) then
    raise exception 'Both players must exist and be active';
  end if;

  if p_first_server not in (p_player_a, p_player_b) then
    raise exception 'First server must be one of the two players';
  end if;

  select start_rating into v_start from seasons where id = v_season;

  -- defensive: make sure both have a stat row this season
  insert into player_season_stats (season_id, player_id, elo, peak_elo)
  select v_season, x, v_start, v_start
  from (values (p_player_a), (p_player_b)) as t(x)
  on conflict (season_id, player_id) do nothing;

  insert into matches (season_id, type, entry_mode, best_of, status,
                       player_a, player_b, color_a, color_b)
  values (v_season, p_type, 'live',
          case p_type when 'series' then 3 else 1 end, 'in_progress',
          p_player_a, p_player_b, p_color_a, p_color_b)
  returning * into v_match;

  insert into games (match_id, game_number, first_server_id, status)
  values (v_match.id, 1, p_first_server, 'in_progress');

  update app_settings
     set current_match_id = v_match.id, table_state = 'in_use', updated_at = now()
   where id = 1;

  return v_match;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. START NEXT GAME  (official+)  -> series only; serve-first is explicit
--    ("anyone may serve first" — the UI asks; we don't guess).
-- ---------------------------------------------------------------------
create or replace function start_game(p_code text, p_match_id uuid, p_first_server uuid)
returns games
language plpgsql security definer set search_path = public as $$
declare
  v_match   matches;
  v_a_games int;
  v_b_games int;
  v_next    int;
  v_needed  int;
  v_game    games;
begin
  perform require_role(p_code, 'official');

  select * into v_match from matches where id = p_match_id;
  if v_match.id is null then raise exception 'Match not found'; end if;
  if v_match.status <> 'in_progress' then raise exception 'Match is not in progress'; end if;
  if v_match.entry_mode <> 'live' then raise exception 'start_game is for live matches only'; end if;

  if exists (select 1 from games where match_id = p_match_id and status = 'in_progress') then
    raise exception 'Finish the current game first';
  end if;

  select count(*) filter (where winner_id = v_match.player_a),
         count(*) filter (where winner_id = v_match.player_b),
         count(*) + 1
    into v_a_games, v_b_games, v_next
  from games where match_id = p_match_id;

  v_needed := case v_match.type when 'series' then 2 else 1 end;
  if v_a_games >= v_needed or v_b_games >= v_needed then
    raise exception 'Match already decided';
  end if;
  if v_next > v_match.best_of then
    raise exception 'No more games in this match';
  end if;
  if p_first_server not in (v_match.player_a, v_match.player_b) then
    raise exception 'First server must be one of the two players';
  end if;

  insert into games (match_id, game_number, first_server_id, status)
  values (p_match_id, v_next, p_first_server, 'in_progress')
  returning * into v_game;

  return v_game;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. ADD A POINT  (official+)  -> live point-by-point; auto-closes the
--    GAME at >=11 win-by-2. Does NOT finalize the match (that's explicit).
-- ---------------------------------------------------------------------
create or replace function add_point(p_code text, p_game_id uuid, p_server uuid, p_scorer uuid)
returns games
language plpgsql security definer set search_path = public as $$
declare
  v_game  games;
  v_match matches;
  v_n     int;
  v_sa    int;
  v_sb    int;
begin
  perform require_role(p_code, 'official');

  select * into v_game from games where id = p_game_id;
  if v_game.id is null then raise exception 'Game not found'; end if;
  if v_game.status <> 'in_progress' then raise exception 'Game is not in progress'; end if;

  select * into v_match from matches where id = v_game.match_id;

  if p_scorer not in (v_match.player_a, v_match.player_b)
     or p_server not in (v_match.player_a, v_match.player_b) then
    raise exception 'Server and scorer must be the two players in this match';
  end if;

  v_sa := v_game.score_a + (case when p_scorer = v_match.player_a then 1 else 0 end);
  v_sb := v_game.score_b + (case when p_scorer = v_match.player_b then 1 else 0 end);

  select coalesce(max(point_number), 0) + 1 into v_n from points where game_id = p_game_id;

  insert into points (game_id, point_number, server_id, scorer_id, score_a_after, score_b_after)
  values (p_game_id, v_n, p_server, p_scorer, v_sa, v_sb);

  update games set score_a = v_sa, score_b = v_sb where id = p_game_id;

  if (v_sa >= 11 or v_sb >= 11) and abs(v_sa - v_sb) >= 2 then
    update games
       set status = 'completed', completed_at = now(),
           winner_id = case when v_sa > v_sb then v_match.player_a else v_match.player_b end
     where id = p_game_id
     returning * into v_game;
  else
    select * into v_game from games where id = p_game_id;
  end if;

  return v_game;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. UNDO LAST POINT  (official+)  -> reverts score, reopens the game if
--    that point had closed it. Blocked once the match is finalized.
-- ---------------------------------------------------------------------
create or replace function remove_last_point(p_code text, p_game_id uuid)
returns games
language plpgsql security definer set search_path = public as $$
declare
  v_game   games;
  v_status match_status;
  v_last   points;
  v_prev   points;
begin
  perform require_role(p_code, 'official');

  select * into v_game from games where id = p_game_id;
  if v_game.id is null then raise exception 'Game not found'; end if;

  select status into v_status from matches where id = v_game.match_id;
  if v_status <> 'in_progress' then
    raise exception 'Match is finalized; cannot undo points';
  end if;

  select * into v_last from points where game_id = p_game_id order by point_number desc limit 1;
  if v_last.id is null then raise exception 'No points to undo'; end if;

  delete from points where id = v_last.id;

  select * into v_prev from points where game_id = p_game_id order by point_number desc limit 1;

  update games
     set score_a = coalesce(v_prev.score_a_after, 0),
         score_b = coalesce(v_prev.score_b_after, 0),
         status = 'in_progress', winner_id = null, completed_at = null
   where id = p_game_id
   returning * into v_game;

  return v_game;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. QUICK FINAL-SCORE UPLOAD  (official+)  -> records a completed game
--    with no point breakdown. Flips the match to 'quick_upload' mode.
-- ---------------------------------------------------------------------
create or replace function submit_game_score(
  p_code text, p_match_id uuid, p_game_number int, p_score_a int, p_score_b int
) returns games
language plpgsql security definer set search_path = public as $$
declare
  v_match matches;
  v_hi    int;
  v_lo    int;
  v_game  games;
begin
  perform require_role(p_code, 'official');

  select * into v_match from matches where id = p_match_id;
  if v_match.id is null then raise exception 'Match not found'; end if;
  if v_match.status <> 'in_progress' then raise exception 'Match is not in progress'; end if;

  v_hi := greatest(p_score_a, p_score_b);
  v_lo := least(p_score_a, p_score_b);
  if v_hi < 11 or (v_hi - v_lo) < 2 then
    raise exception 'Illegal final score: winner needs >=11 and a 2-point margin';
  end if;
  if p_game_number < 1 or p_game_number > v_match.best_of then
    raise exception 'Game number out of range for this match';
  end if;

  update matches set entry_mode = 'quick_upload' where id = p_match_id;

  insert into games (match_id, game_number, score_a, score_b,
                     first_server_id, status, completed_at, winner_id)
  values (p_match_id, p_game_number, p_score_a, p_score_b,
          null, 'completed', now(),
          case when p_score_a > p_score_b then v_match.player_a else v_match.player_b end)
  on conflict (match_id, game_number) do update
     set score_a = excluded.score_a, score_b = excluded.score_b,
         status = 'completed', completed_at = now(), winner_id = excluded.winner_id
  returning * into v_game;

  return v_game;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. COMPLETE MATCH  (official+)  -> the ONLY place ELO is applied.
--    Decides the winner, computes phased K + phased MoV, updates both
--    stat rows (record, streaks, points, peak), writes the ELO snapshot
--    onto the match, and frees the table.
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
  v_formula := case when v_is_swingy then v_season.mov_formula_swingy else v_season.mov_formula_stable end;

  v_mult := mov_multiplier(v_a_pf, v_a_pa, v_season.mov_enabled,
                           v_season.mov_weight, v_season.mov_cap, v_formula);
  v_ea := elo_expected(v_elo_a, v_elo_b);

  v_da := round(v_k * v_mult * ((case when v_winner = v_match.player_a then 1 else 0 end) - v_ea))::int;
  v_db := round(v_k * v_mult * ((case when v_winner = v_match.player_b then 1 else 0 end) - (1 - v_ea)))::int;

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
end;
$$;

-- ---------------------------------------------------------------------
-- 8. CANCEL MATCH  (commissioner)  -> abort an in-progress match, no ELO.
--    A reason is required (UI flow: cancel -> reason -> confirm).
-- ---------------------------------------------------------------------
create or replace function cancel_match(p_code text, p_match_id uuid, p_reason text)
returns matches
language plpgsql security definer set search_path = public as $$
declare v_match matches;
begin
  perform require_role(p_code, 'commissioner');
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reason is required to cancel a match';
  end if;
  select * into v_match from matches where id = p_match_id;
  if v_match.id is null then raise exception 'Match not found'; end if;
  if v_match.status <> 'in_progress' then
    raise exception 'Only an in-progress match can be cancelled';
  end if;
  update matches set status = 'cancelled', completed_at = now(), cancel_reason = btrim(p_reason)
   where id = p_match_id returning * into v_match;
  update app_settings
     set current_match_id = null, table_state = 'open', updated_at = now()
   where id = 1 and current_match_id = p_match_id;
  return v_match;
end;
$$;

-- =====================================================================
--  END OF STEP 4 ENGINE
-- =====================================================================

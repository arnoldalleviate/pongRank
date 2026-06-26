-- =====================================================================
--  TOURNAMENT REPORTING + RANDOM SEEDING + THIRD-PLACE MATCH
-- =====================================================================
--  Run AFTER 01-07 (and 08+). Re-runnable.
--
--  Adds the post-game reporting flow the playerbase actually uses (97% of
--  scores are reported, not live-scored): a tournament game is REPORTED via
--  report_tournament_match (ELO-neutral) and the bracket reacts. The live
--  Play->officiate flow (start_tournament_match / complete_tournament_match)
--  still works and is left intact.
--
--   * seeding_method gains 'random'
--   * start_tournament now also generates a THIRD-PLACE match (semifinal
--     losers, when there's a real semifinal round) wired via loser_next_*
--   * advance_bracket(tm) — shared "winner advances, loser drops to 3rd,
--     final finalizes the tournament" helper used by both finish paths
--   * report_tournament_match(code, tm_id, games) — record a result from
--     final scores, ELO-neutral, advance the bracket
-- =====================================================================

-- 1) random seeding option
alter type seeding_method add value if not exists 'random';

-- ---------------------------------------------------------------------
-- advance_bracket: winner -> next match, loser -> 3rd-place (if wired),
-- and finalize the tournament when the FINAL (not the 3rd-place) is done.
-- The 3rd-place match is tagged group_id = -1 so it never finalizes.
-- ---------------------------------------------------------------------
create or replace function advance_bracket(p_tm_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_tm tournament_matches; v_loser uuid;
begin
  select * into v_tm from tournament_matches where id = p_tm_id;
  if v_tm.winner_id is null then return; end if;
  v_loser := case when v_tm.winner_id = v_tm.player_a then v_tm.player_b else v_tm.player_a end;

  if v_tm.next_match_id is not null then
    if v_tm.next_slot = 'a' then
      update tournament_matches set player_a = v_tm.winner_id where id = v_tm.next_match_id;
    else
      update tournament_matches set player_b = v_tm.winner_id where id = v_tm.next_match_id;
    end if;
  end if;

  if v_tm.loser_next_match_id is not null and v_loser is not null then
    if v_tm.loser_next_slot = 'a' then
      update tournament_matches set player_a = v_loser where id = v_tm.loser_next_match_id;
    else
      update tournament_matches set player_b = v_loser where id = v_tm.loser_next_match_id;
    end if;
  end if;

  -- finalize only when the actual final (no next match, not the 3rd-place game) is decided
  if v_tm.next_match_id is null and coalesce(v_tm.group_id, 0) <> -1 then
    update tournaments set status = 'completed', completed_at = now() where id = v_tm.tournament_id;
  end if;
end; $$;

-- ---------------------------------------------------------------------
-- start_tournament — same single-elim generation as before, PLUS a
-- third-place match wired to the two semifinal losers.
-- ---------------------------------------------------------------------
create or replace function start_tournament(p_code text, p_tournament_id uuid)
returns tournaments
language plpgsql security definer set search_path = public as $$
declare
  v_status  tournament_status;
  v_n int; v_size int; v_rounds int; v_s int;
  v_ord int[] := array[1];
  v_nn int; v_new int[];
  v_seedmap uuid[];
  v_pid uuid;
  r int; pos int; cnt int; i int;
  v_row tournaments;
  r1 record;
  v_third uuid;
begin
  perform require_role(p_code, 'commissioner');
  select status into v_status from tournaments where id = p_tournament_id;
  if v_status is null then raise exception 'Tournament not found'; end if;
  if v_status <> 'setup' then raise exception 'Tournament already started'; end if;

  select count(*) into v_n from tournament_participants where tournament_id = p_tournament_id;
  if v_n < 2 then raise exception 'Need at least 2 players to start'; end if;

  v_size := 2;
  while v_size < v_n loop v_size := v_size * 2; end loop;
  v_rounds := 0; v_s := v_size;
  while v_s > 1 loop v_rounds := v_rounds + 1; v_s := v_s / 2; end loop;

  while array_length(v_ord, 1) < v_size loop
    v_nn := array_length(v_ord, 1);
    v_new := '{}';
    for i in 1 .. v_nn loop
      v_new := v_new || v_ord[i];
      v_new := v_new || (2 * v_nn + 1 - v_ord[i]);
    end loop;
    v_ord := v_new;
  end loop;

  v_seedmap := array_fill(null::uuid, array[v_size]);
  for i in 1 .. v_n loop
    select player_id into v_pid from tournament_participants where tournament_id = p_tournament_id and seed = i;
    v_seedmap[i] := v_pid;
  end loop;

  cnt := v_size / 2;
  for pos in 0 .. cnt - 1 loop
    insert into tournament_matches (tournament_id, bracket, round, position, player_a, player_b)
    values (p_tournament_id, 'winners', 1, pos, v_seedmap[v_ord[2 * pos + 1]], v_seedmap[v_ord[2 * pos + 2]]);
  end loop;

  for r in 2 .. v_rounds loop
    cnt := cnt / 2;
    for pos in 0 .. cnt - 1 loop
      insert into tournament_matches (tournament_id, bracket, round, position)
      values (p_tournament_id, 'winners', r, pos);
    end loop;
  end loop;

  update tournament_matches tm set
    next_match_id = nxt.id,
    next_slot = case when tm.position % 2 = 0 then 'a' else 'b' end
  from tournament_matches nxt
  where tm.tournament_id = p_tournament_id and nxt.tournament_id = p_tournament_id
    and tm.bracket = 'winners' and nxt.bracket = 'winners'
    and nxt.round = tm.round + 1 and nxt.position = tm.position / 2;

  -- third-place match: semifinal losers (only when a semifinal round exists)
  if v_rounds >= 2 then
    insert into tournament_matches (tournament_id, bracket, round, position, group_id)
    values (p_tournament_id, 'winners', v_rounds, 1, -1)
    returning id into v_third;
    update tournament_matches set
      loser_next_match_id = v_third,
      loser_next_slot = case when position = 0 then 'a' else 'b' end
    where tournament_id = p_tournament_id and bracket = 'winners' and round = v_rounds - 1;
  end if;

  -- resolve round-1 byes (player_b null): top seed auto-advances
  for r1 in
    select * from tournament_matches
    where tournament_id = p_tournament_id and bracket = 'winners' and round = 1
      and player_a is not null and player_b is null
  loop
    update tournament_matches set winner_id = r1.player_a where id = r1.id;
    perform advance_bracket(r1.id);
  end loop;

  update tournaments set status = 'active' where id = p_tournament_id returning * into v_row;
  return v_row;
end; $$;

-- ---------------------------------------------------------------------
-- complete_tournament_match (live path) — now uses advance_bracket.
-- ---------------------------------------------------------------------
create or replace function complete_tournament_match(p_code text, p_match_id uuid)
returns tournament_matches
language plpgsql security definer set search_path = public as $$
declare
  v_match matches; v_tm tournament_matches;
  v_a_games int; v_b_games int; v_needed int; v_winner uuid;
begin
  perform require_role(p_code, 'official');
  select * into v_match from matches where id = p_match_id;
  if v_match.id is null then raise exception 'Match not found'; end if;
  if v_match.status <> 'in_progress' then raise exception 'Match is not in progress'; end if;
  if v_match.tournament_match_id is null then raise exception 'Not a tournament match'; end if;

  select count(*) filter (where winner_id = v_match.player_a),
         count(*) filter (where winner_id = v_match.player_b)
    into v_a_games, v_b_games
  from games where match_id = p_match_id and status = 'completed';

  v_needed := case v_match.type when 'series' then 2 else 1 end;
  if v_a_games < v_needed and v_b_games < v_needed then raise exception 'Match is not decided yet'; end if;
  v_winner := case when v_a_games >= v_needed then v_match.player_a else v_match.player_b end;

  update matches set status = 'completed', completed_at = now(), winner_id = v_winner where id = p_match_id;
  update tournament_matches set winner_id = v_winner, match_id = p_match_id
   where id = v_match.tournament_match_id returning * into v_tm;
  perform advance_bracket(v_tm.id);

  update app_settings set current_match_id = null, table_state = 'open', updated_at = now()
   where id = 1 and current_match_id = p_match_id;
  return v_tm;
end; $$;

-- ---------------------------------------------------------------------
-- report_tournament_match (official) — record a bracket result from final
-- scores (no live scoring). ELO-NEUTRAL. p_games = jsonb array of {a,b}.
-- ---------------------------------------------------------------------
create or replace function report_tournament_match(p_code text, p_tm_id uuid, p_games jsonb)
returns tournament_matches
language plpgsql security definer set search_path = public as $$
declare
  v_tm tournament_matches; v_t tournaments; v_match matches;
  v_needed int; v_a_wins int := 0; v_b_wins int := 0; v_winner uuid;
  g jsonb; v_sa int; v_sb int; v_gnum int := 0; v_gwinner uuid;
begin
  perform require_role(p_code, 'official');
  select * into v_tm from tournament_matches where id = p_tm_id;
  if v_tm.id is null then raise exception 'Bracket match not found'; end if;
  select * into v_t from tournaments where id = v_tm.tournament_id;
  if v_t.status <> 'active' then raise exception 'Tournament is not active'; end if;
  if v_tm.player_a is null or v_tm.player_b is null then raise exception 'Both players are not set for this matchup yet'; end if;
  if v_tm.winner_id is not null then raise exception 'This matchup already has a result'; end if;
  if p_games is null or jsonb_array_length(p_games) = 0 then raise exception 'No game scores provided'; end if;

  v_needed := case v_t.match_type when 'series' then 2 else 1 end;

  insert into matches (season_id, type, entry_mode, best_of, status,
                       player_a, player_b, color_a, color_b, tournament_match_id, completed_at)
  values (v_t.season_id, v_t.match_type, 'quick_upload',
          case v_t.match_type when 'series' then 3 else 1 end, 'completed',
          v_tm.player_a, v_tm.player_b, 'blue', 'yellow', v_tm.id, now())
  returning * into v_match;

  for g in select * from jsonb_array_elements(p_games) loop
    v_gnum := v_gnum + 1;
    v_sa := (g->>'a')::int; v_sb := (g->>'b')::int;
    if v_sa is null or v_sb is null or greatest(v_sa, v_sb) < 11 or abs(v_sa - v_sb) < 2 then
      raise exception 'Game % is not a legal result (%-%)', v_gnum, v_sa, v_sb;
    end if;
    v_gwinner := case when v_sa > v_sb then v_tm.player_a else v_tm.player_b end;
    if v_gwinner = v_tm.player_a then v_a_wins := v_a_wins + 1; else v_b_wins := v_b_wins + 1; end if;
    insert into games (match_id, game_number, score_a, score_b, winner_id, status, completed_at)
    values (v_match.id, v_gnum, v_sa, v_sb, v_gwinner, 'completed', now());
  end loop;

  if v_a_wins < v_needed and v_b_wins < v_needed then
    raise exception 'Not enough games to decide the match (need % game win(s))', v_needed;
  end if;
  v_winner := case when v_a_wins >= v_needed then v_tm.player_a else v_tm.player_b end;

  update matches set winner_id = v_winner where id = v_match.id;
  update tournament_matches set winner_id = v_winner, match_id = v_match.id
   where id = v_tm.id returning * into v_tm;
  perform advance_bracket(v_tm.id);

  return v_tm;
end; $$;

-- =====================================================================
--  END — report_tournament_match + 3rd-place + random seeding ready.
-- =====================================================================

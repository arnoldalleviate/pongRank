-- =====================================================================
--  TOURNAMENTS — single-elimination, live  (Step 6 backend)
-- =====================================================================
--  Run AFTER 01-06, in the Supabase SQL Editor. Re-runnable.
--
--  Bracket games are played through the SAME live engine (start ->
--  add_point -> ...), but via tournament-specific start/finish rpcs so they
--  are ELO-NEUTRAL: complete_tournament_match finalizes the match + advances
--  the bracket WITHOUT touching player_season_stats / ELO. The league
--  complete_match is left exactly as-is.
--
--  Double-elim / round-robin: the schema is already wired (loser_next_*,
--  bracket types, group_id) but only single_elim is generated here.
-- =====================================================================

-- ---------------------------------------------------------------------
-- create a tournament (commissioner) — starts in 'setup'
-- ---------------------------------------------------------------------
create or replace function create_tournament(
  p_code text, p_name text, p_match_type match_type, p_seeding_method seeding_method
) returns tournaments
language plpgsql security definer set search_path = public as $$
declare v_season uuid; row tournaments;
begin
  perform require_role(p_code, 'commissioner');
  select active_season_id into v_season from app_settings where id = 1;
  if v_season is null then raise exception 'No active season'; end if;
  insert into tournaments (season_id, name, format, status, seeding_method, match_type)
  values (v_season, trim(p_name), 'single_elim', 'setup', p_seeding_method, p_match_type)
  returning * into row;
  return row;
end; $$;

-- ---------------------------------------------------------------------
-- set the seeded field (commissioner) — ordered player_ids => seeds 1..N
-- (frontend passes them ELO-ordered by default, or in the manual order)
-- ---------------------------------------------------------------------
create or replace function set_tournament_seeds(p_code text, p_tournament_id uuid, p_player_ids uuid[])
returns void
language plpgsql security definer set search_path = public as $$
declare v_status tournament_status; i int;
begin
  perform require_role(p_code, 'commissioner');
  select status into v_status from tournaments where id = p_tournament_id;
  if v_status is null then raise exception 'Tournament not found'; end if;
  if v_status <> 'setup' then raise exception 'Seeds can only be set while the tournament is in setup'; end if;
  if coalesce(array_length(p_player_ids, 1), 0) < 2 then raise exception 'Need at least 2 players'; end if;

  delete from tournament_participants where tournament_id = p_tournament_id;
  for i in 1 .. array_length(p_player_ids, 1) loop
    insert into tournament_participants (tournament_id, player_id, seed)
    values (p_tournament_id, p_player_ids[i], i);
  end loop;
end; $$;

-- ---------------------------------------------------------------------
-- start the tournament (commissioner) — generate the seeded single-elim
-- bracket (byes for the top seeds), wire advancement, flip to 'active'
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
begin
  perform require_role(p_code, 'commissioner');
  select status into v_status from tournaments where id = p_tournament_id;
  if v_status is null then raise exception 'Tournament not found'; end if;
  if v_status <> 'setup' then raise exception 'Tournament already started'; end if;

  select count(*) into v_n from tournament_participants where tournament_id = p_tournament_id;
  if v_n < 2 then raise exception 'Need at least 2 players to start'; end if;

  -- bracket size = next power of 2 >= n; rounds = log2(size)
  v_size := 2;
  while v_size < v_n loop v_size := v_size * 2; end loop;
  v_rounds := 0; v_s := v_size;
  while v_s > 1 loop v_rounds := v_rounds + 1; v_s := v_s / 2; end loop;

  -- standard bracket seed order for v_size (1,8,4,5,2,7,3,6 for size 8)
  while array_length(v_ord, 1) < v_size loop
    v_nn := array_length(v_ord, 1);
    v_new := '{}';
    for i in 1 .. v_nn loop
      v_new := v_new || v_ord[i];
      v_new := v_new || (2 * v_nn + 1 - v_ord[i]);
    end loop;
    v_ord := v_new;
  end loop;

  -- seed -> player map (seed k -> participant seeded k, else null = bye)
  v_seedmap := array_fill(null::uuid, array[v_size]);
  for i in 1 .. v_n loop
    select player_id into v_pid from tournament_participants where tournament_id = p_tournament_id and seed = i;
    v_seedmap[i] := v_pid;
  end loop;

  -- round 1 matches
  cnt := v_size / 2;
  for pos in 0 .. cnt - 1 loop
    insert into tournament_matches (tournament_id, bracket, round, position, player_a, player_b)
    values (p_tournament_id, 'winners', 1, pos, v_seedmap[v_ord[2 * pos + 1]], v_seedmap[v_ord[2 * pos + 2]]);
  end loop;

  -- empty matches for rounds 2..R
  for r in 2 .. v_rounds loop
    cnt := cnt / 2;
    for pos in 0 .. cnt - 1 loop
      insert into tournament_matches (tournament_id, bracket, round, position)
      values (p_tournament_id, 'winners', r, pos);
    end loop;
  end loop;

  -- wire next_match_id / next_slot (position p in round r -> p/2 in round r+1)
  update tournament_matches tm set
    next_match_id = nxt.id,
    next_slot = case when tm.position % 2 = 0 then 'a' else 'b' end
  from tournament_matches nxt
  where tm.tournament_id = p_tournament_id and nxt.tournament_id = p_tournament_id
    and tm.bracket = 'winners' and nxt.bracket = 'winners'
    and nxt.round = tm.round + 1 and nxt.position = tm.position / 2;

  -- resolve round-1 byes (player_b null): top seed auto-advances
  for r1 in
    select * from tournament_matches
    where tournament_id = p_tournament_id and bracket = 'winners' and round = 1
      and player_a is not null and player_b is null
  loop
    update tournament_matches set winner_id = r1.player_a where id = r1.id;
    if r1.next_match_id is not null then
      if r1.next_slot = 'a' then
        update tournament_matches set player_a = r1.player_a where id = r1.next_match_id;
      else
        update tournament_matches set player_b = r1.player_a where id = r1.next_match_id;
      end if;
    end if;
  end loop;

  update tournaments set status = 'active' where id = p_tournament_id returning * into v_row;
  return v_row;
end; $$;

-- ---------------------------------------------------------------------
-- start a bracket match live (commissioner) — creates a real match linked
-- to the bracket slot; played through the normal scoreboard/Officiate flow
-- ---------------------------------------------------------------------
create or replace function start_tournament_match(
  p_code text, p_tournament_match_id uuid, p_first_server uuid,
  p_color_a player_color default 'blue', p_color_b player_color default 'yellow'
) returns matches
language plpgsql security definer set search_path = public as $$
declare
  v_tm tournament_matches;
  v_t  tournaments;
  v_cur uuid;
  v_match matches;
begin
  perform require_role(p_code, 'commissioner');
  select * into v_tm from tournament_matches where id = p_tournament_match_id;
  if v_tm.id is null then raise exception 'Bracket match not found'; end if;
  select * into v_t from tournaments where id = v_tm.tournament_id;
  if v_t.status <> 'active' then raise exception 'Tournament is not active'; end if;
  if v_tm.player_a is null or v_tm.player_b is null then raise exception 'Both players are not set for this matchup yet'; end if;
  if v_tm.winner_id is not null then raise exception 'This matchup already has a result'; end if;

  select current_match_id into v_cur from app_settings where id = 1;
  if v_cur is not null and exists (select 1 from matches where id = v_cur and status = 'in_progress') then
    raise exception 'A match is already in progress';
  end if;

  if p_first_server not in (v_tm.player_a, v_tm.player_b) then
    raise exception 'First server must be one of the two players';
  end if;

  insert into matches (season_id, type, entry_mode, best_of, status,
                       player_a, player_b, color_a, color_b, tournament_match_id)
  values (v_t.season_id, v_t.match_type, 'live',
          case v_t.match_type when 'series' then 3 else 1 end, 'in_progress',
          v_tm.player_a, v_tm.player_b, p_color_a, p_color_b, v_tm.id)
  returning * into v_match;

  insert into games (match_id, game_number, first_server_id, status)
  values (v_match.id, 1, p_first_server, 'in_progress');

  update tournament_matches set match_id = v_match.id where id = v_tm.id;
  update app_settings set current_match_id = v_match.id, table_state = 'in_use', updated_at = now() where id = 1;
  return v_match;
end; $$;

-- ---------------------------------------------------------------------
-- finish a bracket match (official) — decide winner, advance the bracket,
-- free the table. NO ELO / season stats (tournament games are neutral).
-- ---------------------------------------------------------------------
create or replace function complete_tournament_match(p_code text, p_match_id uuid)
returns tournament_matches
language plpgsql security definer set search_path = public as $$
declare
  v_match matches;
  v_tm tournament_matches;
  v_a_games int; v_b_games int; v_needed int;
  v_winner uuid;
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

  if v_tm.next_match_id is not null then
    if v_tm.next_slot = 'a' then
      update tournament_matches set player_a = v_winner where id = v_tm.next_match_id;
    else
      update tournament_matches set player_b = v_winner where id = v_tm.next_match_id;
    end if;
  else
    update tournaments set status = 'completed', completed_at = now() where id = v_tm.tournament_id;
  end if;

  update app_settings set current_match_id = null, table_state = 'open', updated_at = now()
   where id = 1 and current_match_id = p_match_id;

  return v_tm;
end; $$;

-- =====================================================================
--  END OF TOURNAMENTS BACKEND
-- =====================================================================

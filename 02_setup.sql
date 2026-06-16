-- =====================================================================
--  PING PONG LEAGUE — SETUP & HARDENING  (Step 2 of build plan)
-- =====================================================================
--  Run this AFTER 01_schema.sql, in the Supabase SQL Editor.
--  It does three things:
--    1. Stops the browser from ever reading the access codes.
--    2. Adds the rpcs you need to configure + start the league.
--    3. Turns on Realtime for the tables the live UI subscribes to.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. HIDE THE CODES
--    Remove public read on app_settings (it holds the secret codes),
--    then expose only the non-secret fields through an rpc.
-- ---------------------------------------------------------------------
drop policy if exists app_settings_read on app_settings;

-- safe public settings (no codes) for the frontend
create or replace function get_public_settings()
returns table (active_season_id uuid, table_state table_status, current_match_id uuid)
language sql security definer set search_path = public as $$
  select active_season_id, table_state, current_match_id from app_settings where id = 1;
$$;

-- let a person check what role their typed code grants (returns role only,
-- never the codes themselves) so the UI can reveal official/commish controls
create or replace function whoami(p_code text)
returns role
language sql security definer set search_path = public as $$
  select verify_access(p_code);
$$;

-- ---------------------------------------------------------------------
-- 2. CONFIG RPCS
-- ---------------------------------------------------------------------
-- set/rotate the access codes — commissioner only
create or replace function set_access_codes(
  p_code text, p_new_commissioner text, p_new_official text
) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_role(p_code, 'commissioner');
  update app_settings
     set commissioner_code = p_new_commissioner,
         official_code     = p_new_official,
         updated_at        = now()
   where id = 1;
end;
$$;

-- set table state (open / ready / in_use) — official or commissioner
create or replace function set_table_state(p_code text, p_state table_status)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_role(p_code, 'official');
  update app_settings set table_state = p_state, updated_at = now() where id = 1;
end;
$$;

-- activate an upcoming season: flips it to active, sets it as the app's
-- active season, and creates fresh stat rows (full reset) for all active
-- players at the season's start_rating. Commissioner only.
create or replace function activate_season(p_code text, p_season_id uuid)
returns seasons
language plpgsql security definer set search_path = public as $$
declare row seasons;
begin
  perform require_role(p_code, 'commissioner');

  -- archive any currently-active season first (freeze ranks)
  update player_season_stats pss
     set final_rank = sub.rnk
  from (
    select id, rank() over (order by elo desc, wins desc) as rnk
    from player_season_stats
    where season_id = (select active_season_id from app_settings where id = 1)
  ) sub
  where pss.id = sub.id;

  update seasons
     set status = 'archived', archived_at = now()
   where status = 'active';

  -- activate the chosen season
  update seasons set status = 'active' where id = p_season_id returning * into row;
  update app_settings set active_season_id = p_season_id, updated_at = now() where id = 1;

  -- full reset: fresh stat rows for every active player
  insert into player_season_stats (season_id, player_id, elo, peak_elo)
  select row.id, p.id, row.start_rating, row.start_rating
  from players p where p.is_active
  on conflict (season_id, player_id) do nothing;

  return row;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. REALTIME
--    Add the tables the live scoreboard / queue / leaderboard watch.
--    (Supabase ships a publication named supabase_realtime.)
-- ---------------------------------------------------------------------
alter publication supabase_realtime add table matches;
alter publication supabase_realtime add table games;
alter publication supabase_realtime add table points;
alter publication supabase_realtime add table queue;
alter publication supabase_realtime add table player_season_stats;
alter publication supabase_realtime add table tournament_matches;
alter publication supabase_realtime add table app_settings;  -- table_state pushes

-- =====================================================================
--  END OF STEP 2 SQL
-- =====================================================================

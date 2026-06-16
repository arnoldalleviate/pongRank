-- =====================================================================
--  PING PONG LEAGUE — PLAYER MANAGEMENT  (Step 4 backend, players)
-- =====================================================================
--  Run AFTER 01/02/03, in the Supabase SQL Editor. Re-runnable.
--
--  Player roster changes are at the SOLE DISCRETION OF THE COMMISSIONER
--  (refined 2026-06-12). This file:
--    1. Re-gates add_player from official -> commissioner (it shipped as
--       official+ in 01_schema.sql; this create-or-replace overrides it).
--    2. Adds set_player_active for retire / reactivate.
--
--  "Remove" = soft retire (is_active = false): the player drops out of the
--  roster and v_current_standings but ALL match history is preserved
--  (matches reference players with no cascade). There is intentionally NO
--  hard delete — it would either be blocked by FKs or destroy history.
-- =====================================================================

-- ---------------------------------------------------------------------
-- add a player — COMMISSIONER ONLY (was official+ in 01_schema.sql)
-- ---------------------------------------------------------------------
create or replace function add_player(p_code text, p_name text)
returns players
language plpgsql security definer set search_path = public as $$
declare row players;
begin
  perform require_role(p_code, 'commissioner');
  insert into players (name) values (trim(p_name)) returning * into row;
  -- if a season is active, create their stats row at start_rating
  insert into player_season_stats (season_id, player_id, elo, peak_elo)
  select s.active_season_id, row.id, se.start_rating, se.start_rating
  from app_settings s join seasons se on se.id = s.active_season_id
  where s.id = 1 and s.active_season_id is not null;
  return row;
end;
$$;

-- ---------------------------------------------------------------------
-- retire / reactivate a player — COMMISSIONER ONLY
--   p_active = false -> retire (hide from roster + standings, keep history)
--   p_active = true  -> bring them back
-- ---------------------------------------------------------------------
create or replace function set_player_active(p_code text, p_player_id uuid, p_active boolean)
returns players
language plpgsql security definer set search_path = public as $$
declare row players;
begin
  perform require_role(p_code, 'commissioner');
  update players set is_active = p_active where id = p_player_id returning * into row;
  if row.id is null then
    raise exception 'Player not found';
  end if;
  return row;
end;
$$;

-- =====================================================================
--  END OF PLAYER MANAGEMENT
-- =====================================================================

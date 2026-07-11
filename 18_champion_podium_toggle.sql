-- =====================================================================
--  CHAMPION PODIUM TOGGLE — commissioner on/off switch
-- =====================================================================
--  Controls the app-wide champion podium (gold banner + tiled nameplate).
--  The podium now shows the LATEST completed tournament's champion and no
--  longer self-retires at a season flip — the commissioner controls it with
--  this flag instead (default ON). Flip it anytime, no deploy:
--
--    update app_settings set show_champion_podium = false where id = 1;  -- hide
--    update app_settings set show_champion_podium = true  where id = 1;  -- bring back
--
--  (Viewers see the change on their next page load. The permanent 🏆🥈🥉 medal
--   badges and the Season-0 archive are unaffected — they persist regardless.)
--
--  Run AFTER 01-10 (needs get_public_settings). Re-runnable.
-- =====================================================================

alter table app_settings
  add column if not exists show_champion_podium boolean not null default true;

-- get_public_settings gains the flag. RETURNS TABLE shape change needs a drop
-- first (CREATE OR REPLACE can't alter the output columns).
drop function if exists get_public_settings();
create or replace function get_public_settings()
returns table (active_season_id uuid, table_state table_status, current_match_id uuid,
               commissioner_note text, commissioner_note_url text, show_champion_podium boolean)
language sql security definer set search_path = public as $$
  select active_season_id, table_state, current_match_id,
         commissioner_note, commissioner_note_url, show_champion_podium
  from app_settings where id = 1;
$$;

-- =====================================================================
--  END — podium toggle ready (default ON).
-- =====================================================================

-- =====================================================================
--  SEASONS — lever editing + scoring-change transparency  (Step 5 backend)
-- =====================================================================
--  Run AFTER 01-04, in the Supabase SQL Editor. Re-runnable.
--
--  Adds:
--    * seasons.config_version — a counter shown in the UI; bumped each time
--      the commissioner changes a SCORING lever.
--    * season_config_events   — audit log of lever changes (what + when).
--      The match-history list derives its "scoring adjusted here" flag by
--      comparing each match's completed_at against these timestamps, so
--      NOTHING in matches / complete_match has to change.
--    * set_season_config rpc  — commissioner-only; edits a season and, when a
--      scoring lever actually changes, bumps the version + logs the diff.
--
--  (Season create + activate already exist: create_season, activate_season.)
-- =====================================================================

alter table seasons add column if not exists config_version int not null default 1;

create table if not exists season_config_events (
  id          uuid primary key default gen_random_uuid(),
  season_id   uuid not null references seasons(id) on delete cascade,
  version     int  not null,        -- config_version AFTER this change
  changed_at  timestamptz not null default now(),
  changes     jsonb not null        -- { field: [from, to], ... }
);
create index if not exists idx_sce_season on season_config_events(season_id, changed_at);

-- public read (transparency); no direct writes — only the rpc inserts
alter table season_config_events enable row level security;
do $$ begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'season_config_events'
      and policyname = 'season_config_events_read'
  ) then
    create policy season_config_events_read on season_config_events for select using (true);
  end if;
end $$;

-- ---------------------------------------------------------------------
-- edit a season — COMMISSIONER ONLY
--   name/dates are metadata (no version bump). Scoring levers bump the
--   config_version and append a diff to season_config_events, but ONLY when
--   a value actually changes.
-- ---------------------------------------------------------------------
create or replace function set_season_config(
  p_code               text,
  p_season_id          uuid,
  p_name               text,
  p_start_date         date,
  p_end_date           date,
  p_start_rating       int,
  p_elo_floor          int,
  p_k_stable           int,
  p_k_swingy           int,
  p_swingy_after_days  int,
  p_k_override         int,
  p_mov_enabled        boolean,
  p_mov_weight         numeric,
  p_mov_cap            numeric,
  p_mov_formula_stable mov_formula,
  p_mov_formula_swingy mov_formula
) returns seasons
language plpgsql security definer set search_path = public as $$
declare
  o    seasons;
  n    seasons;
  diff jsonb := '{}'::jsonb;
begin
  perform require_role(p_code, 'commissioner');
  select * into o from seasons where id = p_season_id;
  if o.id is null then raise exception 'Season not found'; end if;

  -- build a diff of SCORING fields only (name/dates excluded)
  if o.start_rating       is distinct from p_start_rating       then diff := diff || jsonb_build_object('start_rating',       jsonb_build_array(o.start_rating, p_start_rating)); end if;
  if o.elo_floor          is distinct from p_elo_floor          then diff := diff || jsonb_build_object('elo_floor',          jsonb_build_array(o.elo_floor, p_elo_floor)); end if;
  if o.k_stable           is distinct from p_k_stable           then diff := diff || jsonb_build_object('k_stable',           jsonb_build_array(o.k_stable, p_k_stable)); end if;
  if o.k_swingy           is distinct from p_k_swingy           then diff := diff || jsonb_build_object('k_swingy',           jsonb_build_array(o.k_swingy, p_k_swingy)); end if;
  if o.swingy_after_days  is distinct from p_swingy_after_days  then diff := diff || jsonb_build_object('swingy_after_days',  jsonb_build_array(o.swingy_after_days, p_swingy_after_days)); end if;
  if o.k_override         is distinct from p_k_override         then diff := diff || jsonb_build_object('k_override',         jsonb_build_array(o.k_override, p_k_override)); end if;
  if o.mov_enabled        is distinct from p_mov_enabled        then diff := diff || jsonb_build_object('mov_enabled',        jsonb_build_array(o.mov_enabled, p_mov_enabled)); end if;
  if o.mov_weight         is distinct from p_mov_weight         then diff := diff || jsonb_build_object('mov_weight',         jsonb_build_array(o.mov_weight, p_mov_weight)); end if;
  if o.mov_cap            is distinct from p_mov_cap            then diff := diff || jsonb_build_object('mov_cap',            jsonb_build_array(o.mov_cap, p_mov_cap)); end if;
  if o.mov_formula_stable is distinct from p_mov_formula_stable then diff := diff || jsonb_build_object('mov_formula_stable', jsonb_build_array(o.mov_formula_stable::text, p_mov_formula_stable::text)); end if;
  if o.mov_formula_swingy is distinct from p_mov_formula_swingy then diff := diff || jsonb_build_object('mov_formula_swingy', jsonb_build_array(o.mov_formula_swingy::text, p_mov_formula_swingy::text)); end if;

  update seasons set
    name               = p_name,
    start_date         = p_start_date,
    end_date           = p_end_date,
    start_rating       = p_start_rating,
    elo_floor          = p_elo_floor,
    k_stable           = p_k_stable,
    k_swingy           = p_k_swingy,
    swingy_after_days  = p_swingy_after_days,
    k_override         = p_k_override,
    mov_enabled        = p_mov_enabled,
    mov_weight         = p_mov_weight,
    mov_cap            = p_mov_cap,
    mov_formula_stable = p_mov_formula_stable,
    mov_formula_swingy = p_mov_formula_swingy,
    config_version     = config_version + (case when diff = '{}'::jsonb then 0 else 1 end)
  where id = p_season_id
  returning * into n;

  if diff <> '{}'::jsonb then
    insert into season_config_events (season_id, version, changes)
    values (p_season_id, n.config_version, diff);
  end if;

  return n;
end;
$$;

-- ---------------------------------------------------------------------
-- end the current season — COMMISSIONER ONLY
--   archives the active season (freezing final_rank), leaves NO active
--   season, frees the table, and AUTO-RETIRES ALL PLAYERS so the next
--   season starts from a deliberately re-selected roster. Refuses if a
--   match is still live.
-- ---------------------------------------------------------------------
create or replace function end_season(p_code text)
returns seasons
language plpgsql security definer set search_path = public as $$
declare
  v_active uuid;
  v_cur    uuid;
  row      seasons;
begin
  perform require_role(p_code, 'commissioner');

  select active_season_id, current_match_id into v_active, v_cur from app_settings where id = 1;
  if v_active is null then raise exception 'No active season to end'; end if;

  if v_cur is not null
     and exists (select 1 from matches where id = v_cur and status = 'in_progress') then
    raise exception 'Finish or cancel the live match before ending the season';
  end if;

  -- freeze final ranks on the season being ended
  update player_season_stats pss
     set final_rank = sub.rnk
  from (
    select id, rank() over (order by elo desc, wins desc) as rnk
    from player_season_stats
    where season_id = v_active
  ) sub
  where pss.id = sub.id;

  update seasons set status = 'archived', archived_at = now()
   where id = v_active returning * into row;

  -- no active season; free the table
  update app_settings
     set active_season_id = null, current_match_id = null, table_state = 'open', updated_at = now()
   where id = 1;

  -- auto-retire every player (next season re-selects its roster)
  update players set is_active = false where is_active = true;

  return row;
end;
$$;

-- =====================================================================
--  END OF STEP 5 BACKEND
-- =====================================================================

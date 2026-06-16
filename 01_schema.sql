-- =====================================================================
--  PING PONG LEAGUE — SUPABASE / POSTGRES SCHEMA  (Step 1 of build plan)
-- =====================================================================
--  Architecture: Nuxt 3 (static, GitHub Pages) + Supabase (this DB).
--  No logins. Roles are enforced server-side via ACCESS CODES:
--    - anon (browser) may READ everything (RLS select policies)
--    - anon may NOT write directly (no insert/update/delete policies)
--    - ALL writes go through SECURITY DEFINER rpc functions that verify
--      a code argument against app_settings before mutating.
--  This makes "soft roles without logins" actually enforced by the DB.
--
--  Run this whole file once in the Supabase SQL Editor.
--  Write-path rpc functions are added per-feature in later steps; this
--  file establishes the foundation + the access-code pattern (verify +
--  two representative rpcs: add_player, create_season).
-- =====================================================================

create extension if not exists pgcrypto;   -- gen_random_uuid()

-- =====================================================================
--  ENUMS
-- =====================================================================
create type role            as enum ('viewer','official','commissioner');
create type match_type       as enum ('quick','series');          -- 1 game / best-of-3
create type match_status     as enum ('in_progress','completed','cancelled');
create type entry_mode       as enum ('live','quick_upload');      -- point-by-point vs final score
create type game_status      as enum ('in_progress','completed');
create type season_status    as enum ('upcoming','active','archived');
create type queue_status      as enum ('waiting','playing','done','left');
create type table_status      as enum ('open','ready','in_use');
create type player_color      as enum ('blue','yellow');           -- company colors
create type tournament_format as enum ('single_elim','double_elim','round_robin');
create type tournament_status as enum ('setup','active','completed');
create type bracket_type      as enum ('winners','losers','round_robin'); -- wiring for double-elim/RR
create type seeding_method    as enum ('elo','manual');

-- ordering helper for role comparisons (viewer<official<commissioner)
create or replace function role_rank(r role) returns int
language sql immutable as $$
  select case r
    when 'viewer' then 0
    when 'official' then 1
    when 'commissioner' then 2
  end;
$$;

-- =====================================================================
--  CORE: PLAYERS (identity only — stats live per-season)
-- =====================================================================
create table players (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  is_active   boolean not null default true,   -- soft retire without losing history
  created_at  timestamptz not null default now()
);

-- =====================================================================
--  SEASONS  (commissioner levers live here)
-- =====================================================================
create table seasons (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  status        season_status not null default 'upcoming',
  start_date    date,
  end_date      date,                            -- commissioner sets timeline

  -- ELO config / commissioner levers ---------------------------------
  start_rating  int  not null default 1000,
  elo_floor     int,                             -- 1000 for season 1; null = no floor
  k_stable      int  not null default 20,        -- week 1 "stable"
  k_swingy      int  not null default 40,        -- week 2+ "swingy"
  swingy_after_days int not null default 7,      -- when stable -> swingy flips
  k_override    int,                             -- commissioner hard override (null = use stable/swingy)
  mov_enabled   boolean not null default true,   -- margin-of-victory affects ELO
  mov_weight    numeric not null default 0.5,    -- strength of MoV influence
  mov_cap       numeric not null default 1.75,   -- cap so blowouts stay sane

  created_at    timestamptz not null default now(),
  archived_at   timestamptz
);

-- one active season at a time
create unique index one_active_season
  on seasons (status) where status = 'active';

-- =====================================================================
--  PER-SEASON PLAYER STATS  (resets each season; past rows = archive)
-- =====================================================================
create table player_season_stats (
  id              uuid primary key default gen_random_uuid(),
  season_id       uuid not null references seasons(id) on delete cascade,
  player_id       uuid not null references players(id) on delete cascade,
  elo             int  not null default 1000,
  peak_elo        int  not null default 1000,
  wins            int  not null default 0,
  losses          int  not null default 0,
  games_won       int  not null default 0,
  games_lost      int  not null default 0,
  points_for      int  not null default 0,
  points_against  int  not null default 0,
  current_streak  int  not null default 0,   -- + = win streak, - = loss streak
  best_streak     int  not null default 0,
  matches_played  int  not null default 0,
  final_rank      int,                        -- frozen at archive time
  updated_at      timestamptz not null default now(),
  unique (season_id, player_id)
);
create index idx_pss_season on player_season_stats(season_id);
create index idx_pss_player on player_season_stats(player_id);

-- =====================================================================
--  MATCHES  /  GAMES  /  POINTS
-- =====================================================================
create table matches (
  id            uuid primary key default gen_random_uuid(),
  season_id     uuid not null references seasons(id) on delete cascade,
  type          match_type not null,
  entry_mode    entry_mode not null default 'live',
  best_of       int not null default 1,        -- 1 (quick) or 3 (series)
  status        match_status not null default 'in_progress',

  player_a      uuid not null references players(id),
  player_b      uuid not null references players(id),
  color_a       player_color not null default 'blue',
  color_b       player_color not null default 'yellow',
  winner_id     uuid references players(id),

  -- ELO snapshot for "talking points" / audit
  a_elo_before  int, a_elo_after int, a_elo_change int,
  b_elo_before  int, b_elo_after int, b_elo_change int,

  tournament_match_id uuid,                     -- set if this match is a bracket game (fk added later)
  created_at    timestamptz not null default now(),
  completed_at  timestamptz,
  check (player_a <> player_b)
);
create index idx_matches_season on matches(season_id);
create index idx_matches_status on matches(status);

create table games (
  id              uuid primary key default gen_random_uuid(),
  match_id        uuid not null references matches(id) on delete cascade,
  game_number     int not null,                 -- 1..3
  score_a         int not null default 0,
  score_b         int not null default 0,
  first_server_id uuid not null references players(id),
  winner_id       uuid references players(id),
  status          game_status not null default 'in_progress',
  completed_at    timestamptz,
  unique (match_id, game_number)
);
create index idx_games_match on games(match_id);

-- point-by-point log -> powers serve tracking + heatmaps
create table points (
  id            uuid primary key default gen_random_uuid(),
  game_id       uuid not null references games(id) on delete cascade,
  point_number  int not null,                   -- 1,2,3...
  server_id     uuid not null references players(id),  -- who served this point
  scorer_id     uuid not null references players(id),  -- who won the point
  score_a_after int not null,
  score_b_after int not null,
  created_at    timestamptz not null default now(),
  unique (game_id, point_number)
);
create index idx_points_game on points(game_id);

-- =====================================================================
--  QUEUE  (line for the table)
-- =====================================================================
create table queue (
  id          uuid primary key default gen_random_uuid(),
  season_id   uuid not null references seasons(id) on delete cascade,
  player_id   uuid not null references players(id) on delete cascade,
  position    int not null,
  status      queue_status not null default 'waiting',
  joined_at   timestamptz not null default now()
);
create index idx_queue_season on queue(season_id, status, position);

-- =====================================================================
--  TOURNAMENTS  (single-elim live; wired for double-elim + round-robin)
-- =====================================================================
create table tournaments (
  id              uuid primary key default gen_random_uuid(),
  season_id       uuid not null references seasons(id) on delete cascade,
  name            text not null,
  format          tournament_format not null default 'single_elim',
  status          tournament_status not null default 'setup',
  seeding_method  seeding_method not null default 'elo',
  match_type      match_type not null default 'series', -- bracket games are quick/series
  created_at      timestamptz not null default now(),
  completed_at    timestamptz
);

create table tournament_participants (
  id            uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references tournaments(id) on delete cascade,
  player_id     uuid not null references players(id) on delete cascade,
  seed          int not null,                   -- 1 = top seed
  group_id      int,                            -- round-robin grouping (null for elim)
  unique (tournament_id, player_id),
  unique (tournament_id, seed)
);

create table tournament_matches (
  id              uuid primary key default gen_random_uuid(),
  tournament_id   uuid not null references tournaments(id) on delete cascade,
  bracket         bracket_type not null default 'winners',
  round           int not null,                 -- 1 = first round
  position        int not null,                 -- slot within the round
  player_a        uuid references players(id),  -- null until seeded/advanced
  player_b        uuid references players(id),
  winner_id       uuid references players(id),
  match_id        uuid references matches(id),  -- the actual played match
  -- advancement wiring (works for single + double elim)
  next_match_id   uuid references tournament_matches(id),
  next_slot       char(1),                       -- 'a' or 'b' in the next match
  loser_next_match_id uuid references tournament_matches(id), -- double-elim losers' bracket
  loser_next_slot     char(1),
  group_id        int,                           -- round-robin
  unique (tournament_id, bracket, round, position)
);
create index idx_tmatch_tourn on tournament_matches(tournament_id);

-- now that tournament_matches exists, link matches -> bracket game
alter table matches
  add constraint fk_matches_tmatch
  foreign key (tournament_match_id) references tournament_matches(id);

-- =====================================================================
--  APP SETTINGS  (single row: active season, access codes, table state)
-- =====================================================================
create table app_settings (
  id                int primary key default 1 check (id = 1),
  active_season_id  uuid references seasons(id),
  commissioner_code text not null default 'change-me-commish',
  official_code     text not null default 'change-me-official',
  table_state       table_status not null default 'open',
  current_match_id  uuid references matches(id),
  updated_at        timestamptz not null default now()
);
insert into app_settings (id) values (1) on conflict do nothing;

-- =====================================================================
--  ACCESS-CODE VERIFICATION  (the heart of role enforcement)
-- =====================================================================
-- returns the role a given code grants ('viewer' if blank/unknown)
create or replace function verify_access(p_code text)
returns role
language plpgsql security definer set search_path = public as $$
declare s app_settings;
begin
  select * into s from app_settings where id = 1;
  if p_code is not null and p_code = s.commissioner_code then return 'commissioner';
  elsif p_code is not null and p_code = s.official_code  then return 'official';
  else return 'viewer';
  end if;
end;
$$;

-- guard helper: raise if the code doesn't meet the minimum role
create or replace function require_role(p_code text, p_min role)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if role_rank(verify_access(p_code)) < role_rank(p_min) then
    raise exception 'Access denied: requires % role', p_min
      using errcode = '42501';
  end if;
end;
$$;

-- =====================================================================
--  REPRESENTATIVE WRITE RPCS  (pattern for all later write paths)
-- =====================================================================
-- add a player — officials or commissioner
create or replace function add_player(p_code text, p_name text)
returns players
language plpgsql security definer set search_path = public as $$
declare row players;
begin
  perform require_role(p_code, 'official');
  insert into players (name) values (trim(p_name)) returning * into row;
  -- if a season is active, create their stats row at start_rating
  insert into player_season_stats (season_id, player_id, elo, peak_elo)
  select s.active_season_id, row.id, se.start_rating, se.start_rating
  from app_settings s join seasons se on se.id = s.active_season_id
  where s.id = 1 and s.active_season_id is not null;
  return row;
end;
$$;

-- create a season — commissioner only
create or replace function create_season(
  p_code text, p_name text, p_start date, p_end date,
  p_elo_floor int default null
) returns seasons
language plpgsql security definer set search_path = public as $$
declare row seasons;
begin
  perform require_role(p_code, 'commissioner');
  insert into seasons (name, start_date, end_date, elo_floor, status)
  values (p_name, p_start, p_end, p_elo_floor, 'upcoming')
  returning * into row;
  return row;
end;
$$;

-- =====================================================================
--  VIEWS  (read models the frontend leans on)
-- =====================================================================
-- live standings for the active season, ranked by elo
create or replace view v_current_standings as
select
  rank() over (order by pss.elo desc, pss.wins desc) as rank,
  p.id as player_id, p.name, pss.season_id,
  pss.elo, pss.peak_elo, pss.wins, pss.losses,
  pss.games_won, pss.games_lost, pss.points_for, pss.points_against,
  pss.current_streak, pss.best_streak, pss.matches_played
from player_season_stats pss
join players p on p.id = pss.player_id
join app_settings s on s.id = 1 and s.active_season_id = pss.season_id
where p.is_active;

-- head-to-head record between any two players (completed matches)
create or replace view v_head_to_head as
select
  least(player_a::text, player_b::text)    as p1,
  greatest(player_a::text, player_b::text) as p2,
  count(*) as matches_played,
  count(*) filter (where winner_id::text = least(player_a::text, player_b::text))    as p1_wins,
  count(*) filter (where winner_id::text = greatest(player_a::text, player_b::text)) as p2_wins
from matches
where status = 'completed'
group by 1,2;

-- =====================================================================
--  ROW-LEVEL SECURITY  (read = everyone; write = rpc-only)
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array[
    'players','seasons','player_season_stats','matches','games','points',
    'queue','tournaments','tournament_participants','tournament_matches','app_settings'
  ] loop
    execute format('alter table %I enable row level security;', t);
    -- public read
    execute format(
      'create policy %I on %I for select using (true);', t||'_read', t);
    -- NO insert/update/delete policies => anon cannot write directly.
    -- All mutations flow through SECURITY DEFINER rpc functions above.
  end loop;
end $$;

-- app_settings codes should not be world-readable; restrict that view later
-- via a dedicated rpc. (Flagged for Step 2 hardening.)

-- =====================================================================
--  END OF STEP 1
-- =====================================================================

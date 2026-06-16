-- =====================================================================
--  SEED 20 TEST PLAYERS  —  run once in the Supabase SQL Editor
-- =====================================================================
--  These are placeholder/test names — rename or retire any of them later
--  from the Players page. Keeps the existing Alice & Ben (pool -> 22).
--
--  Direct inserts: the SQL Editor runs as a privileged role, so no access
--  code is needed here (this bypasses the commissioner-gated add_player rpc
--  on purpose, for a one-shot bulk seed). It also creates each player's
--  Season-1 stat row at the season start_rating (1000) so they appear on
--  the leaderboard right away.
--
--  Re-runnable: existing names are skipped, existing stat rows untouched.
-- =====================================================================

with ins as (
  insert into players (name) values
    ('Mia Chen'),     ('Raj Patel'),    ('Diego Alvarez'), ('Sofia Rossi'),
    ('Liam O''Brien'),('Nina Petrova'), ('Omar Haddad'),   ('Grace Kim'),
    ('Tom Becker'),   ('Priya Nair'),   ('Marco Bianchi'), ('Hana Suzuki'),
    ('Felix Wagner'), ('Zoe Martin'),   ('Kofi Mensah'),   ('Elena Garcia'),
    ('Jonas Berg'),   ('Aisha Khan'),   ('Caleb Wright'),  ('Yuki Tanaka')
  on conflict (name) do nothing
  returning id
)
insert into player_season_stats (season_id, player_id, elo, peak_elo)
select s.active_season_id, ins.id, se.start_rating, se.start_rating
from ins
cross join app_settings s
join seasons se on se.id = s.active_season_id
where s.id = 1 and s.active_season_id is not null
on conflict (season_id, player_id) do nothing;

-- quick checks (the SQL Editor shows the last result grid)
select count(*) as total_players from players;
select rank, name, elo from v_current_standings order by rank, name;

-- =====================================================================
--  EXEC DAY  (Friday — temporary chaos, run once, revert after)
-- =====================================================================
--  * Erin & Jeff get 5000 ELO (Jeff shows on the board at 0-0 thanks to the
--    leaderboard's "manually-rated players appear even at 0 games" rule).
--  * ELO swings 50× harder: k_override = 2000 (50 × the base K of 40).
--
--  On the current binary + MoV engine (cap 1.75), per-match swing range:
--    even match: ±1000 (close) … ±1750 (blowout)
--    beating a 5000 exec: +2000 … +3500 (the exec drops the same, floored at 500)
--
--  REVERT after exec day:
--    update seasons set k_override = 160 where id = (select active_season_id from app_settings where id = 1);
--    -- (and reset Erin/Jeff ELO to taste if desired)
-- =====================================================================

-- make sure Jeff is active
update players set is_active = true where name = 'Jeff';

-- Erin & Jeff → 5000 ELO
update player_season_stats set elo = 5000, updated_at = now()
where season_id = (select active_season_id from app_settings where id = 1)
  and player_id in (select id from players where name in ('Erin', 'Jeff'));

-- ELO swings 50× harder
update seasons set k_override = 2000
where id = (select active_season_id from app_settings where id = 1);

-- =====================================================================
--  END EXEC DAY — let the carnage commence.
-- =====================================================================

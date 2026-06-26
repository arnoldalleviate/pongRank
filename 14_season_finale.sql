-- =====================================================================
--  SEASON 0 FINALE BANNER  (run when you close out the season)
-- =====================================================================
--  Swaps the commissioner banner (leaderboard + match log) to the Season 0
--  send-off and links the finale writeup. Replace/clear when Season 1 opens:
--    update app_settings set commissioner_note = null, commissioner_note_url = null where id = 1;
-- =====================================================================

update app_settings set
  commissioner_note =
    '🏓 Season 0 — that''s a wrap. Thank you for every match, every nail-biter, every upset. It was always about getting everyone around the table, and you delivered. Tap Details for the full send-off.',
  commissioner_note_url =
    'https://github.com/arnoldalleviate/pongRank/blob/dev/docs/season-0-finale.md'
where id = 1;

-- =====================================================================
--  END — GG, Season 0.
-- =====================================================================

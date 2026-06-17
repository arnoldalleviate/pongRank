-- =====================================================================
--  COMMISSIONER NOTE — a public announcement banner (shown in Recent matches)
-- =====================================================================
--  A single editable message the commissioner can post site-wide (e.g. to
--  explain a scoring change). Public-readable via get_public_settings; set it
--  from the Supabase table editor or:
--    update app_settings set commissioner_note = 'your message' where id = 1;
--  Clear it with:
--    update app_settings set commissioner_note = null where id = 1;
--
--  Run AFTER 01-09 in the Supabase SQL Editor. Re-runnable. (NOTE: re-running
--  resets the message text below — edit the text here or skip the final UPDATE
--  if you've since changed it in the app/DB.)
-- =====================================================================

alter table app_settings add column if not exists commissioner_note     text;
alter table app_settings add column if not exists commissioner_note_url text;  -- optional "Details →" link

-- get_public_settings gains the note + its link (changing the RETURNS TABLE
-- shape needs a drop first — CREATE OR REPLACE can't alter the output columns).
drop function if exists get_public_settings();
create or replace function get_public_settings()
returns table (active_season_id uuid, table_state table_status, current_match_id uuid,
               commissioner_note text, commissioner_note_url text)
language sql security definer set search_path = public as $$
  select active_season_id, table_state, current_match_id, commissioner_note, commissioner_note_url
  from app_settings where id = 1;
$$;

-- initial announcement for the ELO scoring change, linking the full writeup
update app_settings set
  commissioner_note =
    'Scoring update: ELO now reflects how decisively each match is played — ratings move on per-match performance, not just the win or loss. Close matches barely shift; blowouts and dominant series shift the most. The rating floor is now 900.',
  commissioner_note_url =
    'https://github.com/arnoldalleviate/pongRank/blob/dev/docs/season-0.5-elo-update.md'
where id = 1;

-- =====================================================================
--  END OF COMMISSIONER NOTE
-- =====================================================================

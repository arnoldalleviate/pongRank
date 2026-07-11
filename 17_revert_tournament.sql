-- =====================================================================
--  REVERT A TOURNAMENT RESULT  (commissioner)
-- =====================================================================
--  Run AFTER 07 + 13. Re-runnable.
--
--  Undoes ONE reported/live bracket result and re-opens the slot for a
--  fresh report. Tournament games are ELO-NEUTRAL, so there is no rating
--  math to reverse — this only unwinds the bracket wiring + hard-deletes
--  the played match (games/points cascade).
--
--  It REFUSES if the winner's next match or the loser's 3rd-place match
--  already has a result (revert those first) so it can't strand a player
--  in an already-played round.
--
--  After a successful revert the slot keeps both players but has
--  winner_id = null / match_id = null, ready to be reported again.
-- =====================================================================

create or replace function revert_tournament_match(p_code text, p_tm_id uuid)
returns tournament_matches
language plpgsql security definer set search_path = public as $$
declare
  v_tm       tournament_matches;
  v_match_id uuid;
  v_loser    uuid;
  v_next     tournament_matches;
  v_lnext    tournament_matches;
begin
  perform require_role(p_code, 'commissioner');

  select * into v_tm from tournament_matches where id = p_tm_id;
  if v_tm.id is null then raise exception 'Bracket match not found'; end if;
  if v_tm.winner_id is null then raise exception 'This matchup has no result to revert'; end if;

  v_match_id := v_tm.match_id;
  v_loser := case when v_tm.winner_id = v_tm.player_a then v_tm.player_b else v_tm.player_a end;

  -- guard: winner's next match must not be decided yet
  if v_tm.next_match_id is not null then
    select * into v_next from tournament_matches where id = v_tm.next_match_id;
    if v_next.winner_id is not null then
      raise exception 'Cannot revert: the next match (round %, pos %) already has a result. Revert that one first.',
        v_next.round, v_next.position;
    end if;
  end if;

  -- guard: loser's 3rd-place match must not be decided yet
  if v_tm.loser_next_match_id is not null then
    select * into v_lnext from tournament_matches where id = v_tm.loser_next_match_id;
    if v_lnext.winner_id is not null then
      raise exception 'Cannot revert: the 3rd-place match already has a result. Revert that one first.';
    end if;
  end if;

  -- 1) pull the winner back out of the next slot
  if v_tm.next_match_id is not null then
    if v_tm.next_slot = 'a' then
      update tournament_matches set player_a = null where id = v_tm.next_match_id;
    else
      update tournament_matches set player_b = null where id = v_tm.next_match_id;
    end if;
  end if;

  -- 2) pull the loser back out of the 3rd-place slot
  if v_tm.loser_next_match_id is not null and v_loser is not null then
    if v_tm.loser_next_slot = 'a' then
      update tournament_matches set player_a = null where id = v_tm.loser_next_match_id;
    else
      update tournament_matches set player_b = null where id = v_tm.loser_next_match_id;
    end if;
  end if;

  -- 3) if this was the final, un-finalize the tournament
  if v_tm.next_match_id is null and coalesce(v_tm.group_id, 0) <> -1 then
    update tournaments set status = 'active', completed_at = null where id = v_tm.tournament_id;
  end if;

  -- 4) clear the result + unlink the played match, then hard-delete it
  update tournament_matches set winner_id = null, match_id = null
   where id = v_tm.id returning * into v_tm;

  if v_match_id is not null then
    -- free the table if (somehow) this was the current live match
    update app_settings set current_match_id = null, table_state = 'open', updated_at = now()
     where id = 1 and current_match_id = v_match_id;
    -- games + points cascade on delete
    delete from matches where id = v_match_id;
  end if;

  return v_tm;
end; $$;

-- =====================================================================
--  END — revert_tournament_match ready.
-- =====================================================================

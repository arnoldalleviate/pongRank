-- =====================================================================
--  OFFICIATE — point editing  (Step 4.5 backend, for the Officiate dashboard)
-- =====================================================================
--  Run AFTER 01-04 (05 optional), in the Supabase SQL Editor. Re-runnable.
--
--  flip_point: the timeline lets an official tap a point-box to switch which
--  player scored it (fix a mis-attributed point). This flips the scorer, then
--  recomputes the running score for that point AND every later point in the
--  game, and re-derives the game's winner/completed status from the final
--  score. Blocked once the match is finalized (ELO already applied).
--
--  Note: it trusts the logged point sequence and lets the FINAL score decide
--  completion — it won't retro-truncate points if an edit would have ended the
--  game earlier. Fine for live correction of recent points.
-- =====================================================================

create or replace function flip_point(p_code text, p_point_id uuid)
returns games
language plpgsql security definer set search_path = public as $$
declare
  v_pt    points;
  v_game  games;
  v_match matches;
  v_a      int;
  v_b      int;
  v_done   boolean;
  v_status game_status;
  v_winner uuid;
begin
  perform require_role(p_code, 'official');

  select * into v_pt from points where id = p_point_id;
  if v_pt.id is null then raise exception 'Point not found'; end if;
  select * into v_game from games where id = v_pt.game_id;
  select * into v_match from matches where id = v_game.match_id;
  if v_match.status <> 'in_progress' then
    raise exception 'Match is finalized; cannot edit points';
  end if;

  -- flip the scorer to the other player
  update points
     set scorer_id = case when scorer_id = v_match.player_a then v_match.player_b else v_match.player_a end
   where id = p_point_id;

  -- recompute running score for every point in the game, in order
  with seq as (
    select id,
      sum(case when scorer_id = v_match.player_a then 1 else 0 end) over (order by point_number) as a_after,
      sum(case when scorer_id = v_match.player_b then 1 else 0 end) over (order by point_number) as b_after
    from points where game_id = v_game.id
  )
  update points p
     set score_a_after = seq.a_after, score_b_after = seq.b_after
  from seq where seq.id = p.id;

  -- final score = last point's running score
  select score_a_after, score_b_after into v_a, v_b
  from points where game_id = v_game.id order by point_number desc limit 1;
  if not found then v_a := 0; v_b := 0; end if;

  v_done := (v_a >= 11 or v_b >= 11) and abs(v_a - v_b) >= 2;

  if v_done then
    v_status := 'completed';
    v_winner := case when v_a > v_b then v_match.player_a else v_match.player_b end;
  else
    v_status := 'in_progress';
    v_winner := null;
  end if;

  update games set
    score_a = v_a, score_b = v_b,
    status = v_status,
    winner_id = v_winner,
    completed_at = case when v_done then now() else null end
  where id = v_game.id
  returning * into v_game;

  return v_game;
end;
$$;

-- ---------------------------------------------------------------------
-- flip the first server (official) — quick fix when the wrong server was
-- picked. Allowed only within the first 5 serves (score_a+score_b <= 5),
-- so every point so far belongs to the first server: flip first_server_id
-- and reassign those points' server_id to the new server.
-- ---------------------------------------------------------------------
create or replace function flip_first_server(p_code text, p_game_id uuid)
returns games
language plpgsql security definer set search_path = public as $$
declare
  v_game  games;
  v_match matches;
  v_new   uuid;
begin
  perform require_role(p_code, 'official');
  select * into v_game from games where id = p_game_id;
  if v_game.id is null then raise exception 'Game not found'; end if;
  if v_game.status <> 'in_progress' then raise exception 'Game is not in progress'; end if;
  select * into v_match from matches where id = v_game.match_id;
  if v_match.status <> 'in_progress' then raise exception 'Match is not in progress'; end if;
  if (v_game.score_a + v_game.score_b) > 5 then
    raise exception 'The server can only be flipped within the first 5 serves';
  end if;

  v_new := case when v_game.first_server_id = v_match.player_a then v_match.player_b else v_match.player_a end;
  update games set first_server_id = v_new where id = p_game_id returning * into v_game;
  update points set server_id = v_new where game_id = p_game_id;   -- all in the first serve block
  return v_game;
end; $$;

-- =====================================================================
--  END OF OFFICIATE BACKEND
-- =====================================================================

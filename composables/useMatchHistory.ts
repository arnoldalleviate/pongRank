// Completed-match history for the active season, newest first.
//  - Enriches each match with winner/loser names, a score line, and ELO deltas.
//  - Derives the "scoring adjusted" flag WITHOUT any extra DB columns: each
//    match's effective config version = 1 + (# of season_config_events at or
//    before its completed_at). A match is flagged when its version is higher
//    than the next-older match's — i.e. the scoring system changed right
//    before it ("flag only at the change").
import type { RealtimeChannel } from '@supabase/supabase-js'
import { ref } from 'vue'

export function useMatchHistory() {
  const supabase = useSupabase()
  const matches = ref<any[]>([])
  const loading = ref(true)
  const err = ref<string | null>(null)
  let channel: RealtimeChannel | null = null

  function summarize(m: any) {
    const games = (m.games ?? []).slice().sort((a: any, b: any) => a.game_number - b.game_number)
    const detail = games.map((g: any) => `${g.score_a}-${g.score_b}`)
    if (m.type === 'series') {
      const aw = games.filter((g: any) => g.winner_id === m.player_a).length
      const bw = games.filter((g: any) => g.winner_id === m.player_b).length
      return { scoreLine: `${Math.max(aw, bw)}–${Math.min(aw, bw)}`, detail }
    }
    const g = games[0]
    return { scoreLine: g ? `${Math.max(g.score_a, g.score_b)}–${Math.min(g.score_a, g.score_b)}` : '—', detail }
  }

  async function load() {
    try {
      const { data: s } = await supabase.rpc('get_public_settings')
      const seasonId = (Array.isArray(s) ? s[0] : s)?.active_season_id
      if (!seasonId) { matches.value = []; return }

      const [mRes, pRes, eRes] = await Promise.all([
        supabase.from('matches')
          .select('id,type,entry_mode,player_a,player_b,winner_id,a_elo_change,b_elo_change,completed_at,games(game_number,score_a,score_b,winner_id)')
          .eq('season_id', seasonId).eq('status', 'completed')
          .order('completed_at', { ascending: false }),
        supabase.from('players').select('id,name'),
        supabase.from('season_config_events').select('changed_at')
          .eq('season_id', seasonId).order('changed_at', { ascending: true }),
      ])
      if (mRes.error) { err.value = mRes.error.message; return }

      const names: Record<string, string> = Object.fromEntries((pRes.data ?? []).map((p: any) => [p.id, p.name]))
      const eventTimes = (eRes.data ?? []).map((e: any) => new Date(e.changed_at).getTime())

      // enrich + effective config version
      const enriched = (mRes.data ?? []).map((m: any) => {
        const t = m.completed_at ? new Date(m.completed_at).getTime() : 0
        const version = 1 + eventTimes.filter((et) => et <= t).length
        const winnerIsA = m.winner_id === m.player_a
        const { scoreLine, detail } = summarize(m)
        return {
          id: m.id,
          completed_at: m.completed_at,
          type: m.type,
          entry_mode: m.entry_mode,
          winnerName: names[m.winner_id] ?? '—',
          loserName: names[winnerIsA ? m.player_b : m.player_a] ?? '—',
          scoreLine,
          detail,                                   // e.g. ['11-7','9-11','11-8'] (future tooltip)
          winnerElo: winnerIsA ? m.a_elo_change : m.b_elo_change,
          loserElo: winnerIsA ? m.b_elo_change : m.a_elo_change,
          version,
        }
      })

      // flag the change points (list is newest-first; baseline before season = v1)
      matches.value = enriched.map((m, i) => {
        const olderVersion = i + 1 < enriched.length ? enriched[i + 1].version : 1
        return { ...m, scoringAdjusted: m.version > olderVersion }
      })
    } finally {
      loading.value = false
    }
  }

  function subscribe() {
    channel = supabase
      .channel('match-history')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'matches' }, () => load())
      .on('postgres_changes', { event: '*', schema: 'public', table: 'season_config_events' }, () => load())
      .subscribe()
  }
  function unsubscribe() {
    if (channel) { supabase.removeChannel(channel); channel = null }
  }

  return { matches, loading, err, load, subscribe, unsubscribe }
}

// Match history for the active season, newest first — completed AND cancelled.
//  - Completed: winner/loser names, score line, ELO deltas.
//  - Cancelled: both player names + the cancel reason; no result/ELO.
//  - Derives the "scoring adjusted" flag WITHOUT any extra DB columns: each
//    match's effective config version = 1 + (# of season_config_events at or
//    before its completed_at). A completed match is flagged when its version is
//    higher than the next-older completed match's ("flag only at the change");
//    cancelled matches never applied ELO, so they're never flagged.
import type { RealtimeChannel } from '@supabase/supabase-js'
import { ref } from 'vue'

export function useMatchHistory() {
  const supabase = useSupabase()
  const { accessCode } = useRole()
  const matches = ref<any[]>([])
  const loading = ref(true)
  const err = ref<string | null>(null)
  const busy = ref(false)
  const note = ref<string | null>(null)       // commissioner announcement banner
  const noteUrl = ref<string | null>(null)    // optional "Details →" link for the note
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
      const settings = Array.isArray(s) ? s[0] : s
      note.value = settings?.commissioner_note ?? null
      noteUrl.value = settings?.commissioner_note_url ?? null
      const seasonId = settings?.active_season_id
      if (!seasonId) { matches.value = []; return }

      const [mRes, pRes, eRes] = await Promise.all([
        supabase.from('matches')
          .select('id,type,entry_mode,status,cancel_reason,player_a,player_b,winner_id,a_elo_change,b_elo_change,completed_at,games(game_number,score_a,score_b,winner_id)')
          .eq('season_id', seasonId).in('status', ['completed', 'cancelled'])
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
          status: m.status,                         // 'completed' | 'cancelled'
          cancelReason: m.cancel_reason ?? null,
          type: m.type,
          entry_mode: m.entry_mode,
          playerAName: names[m.player_a] ?? '—',
          playerBName: names[m.player_b] ?? '—',
          winnerName: names[m.winner_id] ?? '—',
          loserName: names[winnerIsA ? m.player_b : m.player_a] ?? '—',
          scoreLine,
          detail,                                   // e.g. ['11-7','9-11','11-8']
          winnerElo: winnerIsA ? m.a_elo_change : m.b_elo_change,
          loserElo: winnerIsA ? m.b_elo_change : m.a_elo_change,
          version,
        }
      })

      // Flag scoring-config change points — across COMPLETED matches only.
      // Walk oldest→newest (baseline before the season = v1); flag the first
      // completed match at each higher version. Cancelled matches never applied
      // ELO, so they're skipped here and stay unflagged.
      const flagged = new Set<string>()
      let prevVersion = 1
      for (const m of [...enriched].filter((m) => m.status === 'completed').reverse()) {
        if (m.version > prevVersion) flagged.add(m.id)
        prevVersion = m.version
      }
      matches.value = enriched.map((m) => ({ ...m, scoringAdjusted: flagged.has(m.id) }))
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

  async function deleteMatch(matchId: string) {
    busy.value = true
    const { error } = await supabase.rpc('delete_match', { p_code: accessCode.value, p_match_id: matchId })
    if (error) err.value = error.message
    else await load()
    busy.value = false
    return !error
  }

  return { matches, loading, err, busy, note, noteUrl, load, subscribe, unsubscribe, deleteMatch }
}

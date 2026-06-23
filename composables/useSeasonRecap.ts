// Season infographics for the active season — totals computed live from the
// completed league matches + their games. Lives on the leaderboard; freezes
// into the season archive on rollover (future). Awards/titles are curated
// separately (see pages/index.vue AWARDS) since they carry bespoke copy.
import { ref } from 'vue'

export function useSeasonRecap() {
  const supabase = useSupabase()
  const stats = ref<any | null>(null)
  const loading = ref(true)
  const note = ref<string | null>(null)       // commissioner announcement
  const noteUrl = ref<string | null>(null)

  async function load() {
    const { data: s } = await supabase.rpc('get_public_settings')
    const set = Array.isArray(s) ? s[0] : s
    note.value = set?.commissioner_note ?? null
    noteUrl.value = set?.commissioner_note_url ?? null
    const seasonId = set?.active_season_id
    if (!seasonId) { loading.value = false; return }

    const { data } = await supabase
      .from('matches')
      .select('id,completed_at,games(score_a,score_b)')
      .eq('season_id', seasonId).eq('status', 'completed').is('tournament_match_id', null)

    const matches = data ?? []
    let games = 0, points = 0, close = 0
    let biggestMargin = -1, biggestGame = '—', highTotal = -1, highGame = '—'
    const byDay: Record<string, number> = {}
    const fmt = (a: number, b: number) => `${Math.max(a, b)}–${Math.min(a, b)}`

    for (const m of matches) {
      const d = (m.completed_at || '').slice(0, 10)
      if (d) byDay[d] = (byDay[d] || 0) + 1
      for (const g of (m.games ?? [])) {
        games++
        const tot = g.score_a + g.score_b
        points += tot
        const margin = Math.abs(g.score_a - g.score_b)
        if (margin <= 3) close++
        if (margin > biggestMargin) { biggestMargin = margin; biggestGame = fmt(g.score_a, g.score_b) }
        if (tot > highTotal) { highTotal = tot; highGame = fmt(g.score_a, g.score_b) }
      }
    }
    const busiest = Object.entries(byDay).sort((a, b) => b[1] - a[1])[0]

    stats.value = {
      matches: matches.length,
      games,
      points,
      close,
      closePct: games ? Math.round((close / games) * 100) : 0,
      avg: games ? (points / games).toFixed(1) : '0',
      biggestGame,
      highGame,
      busiestCount: busiest?.[1] ?? 0,
    }
    loading.value = false
  }

  return { stats, loading, note, noteUrl, load }
}

// Champions derived from COMPLETED tournaments. Two views, on purpose:
//   - currentChampion: the champion of a completed tournament in the *active*
//     season. Drives the loud, app-wide celebration (banner + confetti) and
//     self-retires the moment the season flips — a new season owns no completed
//     tournament yet, so this goes null with no code change or deploy timing.
//   - badgeByName: name -> championship info across ALL completed tournaments.
//     A permanent honor that persists across seasons (the little leaderboard 🏆).
import { ref, computed } from 'vue'

export function useChampion() {
  const supabase = useSupabase()
  const champions = ref<any[]>([])          // most-recent first
  const showPodium = ref(true)              // commissioner toggle: app_settings.show_champion_podium
  const loaded = ref(false)

  // "Season 0" -> "S0"; anything else falls back to the full tournament name.
  function shortLabel(name: string) {
    const m = /season\s+(\d+)/i.exec(name)
    return m ? `S${m[1]}` : name
  }

  async function load() {
    const { data: s } = await supabase.rpc('get_public_settings')
    showPodium.value = (Array.isArray(s) ? s[0] : s)?.show_champion_podium ?? true

    const { data: ts } = await supabase
      .from('tournaments')
      .select('id,name,season_id,completed_at')
      .eq('status', 'completed')
      .order('completed_at', { ascending: false })

    const { data: players } = await supabase.from('players').select('id,name')
    const pn: Record<string, string> = Object.fromEntries((players ?? []).map((p: any) => [p.id, p.name]))

    const out: any[] = []
    for (const tourney of ts ?? []) {
      // The final = the winners-bracket match with no next match that isn't the
      // 3rd-place game (group_id -1). Its winner is the champion.
      const { data: ends } = await supabase
        .from('tournament_matches')
        .select('*')
        .eq('tournament_id', tourney.id)
        .is('next_match_id', null)
      const final = (ends ?? []).find((m: any) => (m.group_id ?? 0) !== -1 && m.winner_id)
      if (!final) continue

      const championId = final.winner_id
      const runnerUpId = final.player_a === championId ? final.player_b : final.player_a
      // Bronze = winner of the 3rd-place match (group_id -1). It also has no
      // next match, so it's already in `ends`. Absent for < 4-player brackets.
      const third = (ends ?? []).find((m: any) => (m.group_id ?? 0) === -1 && m.winner_id)

      out.push({
        tournamentId: tourney.id,
        name: tourney.name,
        label: shortLabel(tourney.name),
        seasonId: tourney.season_id,
        championId,
        championName: pn[championId] ?? null,
        silverName: runnerUpId ? (pn[runnerUpId] ?? null) : null,
        bronzeName: third?.winner_id ? (pn[third.winner_id] ?? null) : null,
      })
    }

    champions.value = out
    loaded.value = true
  }

  // reigning champion = latest completed tournament's winner, shown while the
  // commissioner toggle is on. Persists across seasons; flip via app_settings
  // (show_champion_podium) — no longer tied to the active season.
  const currentChampion = computed(
    () => (showPodium.value ? (champions.value[0] ?? null) : null),
  )

  // permanent: name -> that player's most-recent podium placement (survives
  // season resets). Champion / runner-up / 3rd all get a tag.
  const PODIUM = [
    { key: 'championName', rank: 1, medal: '🏆', title: 'Champion' },
    { key: 'silverName', rank: 2, medal: '🥈', title: 'Runner-up' },
    { key: 'bronzeName', rank: 3, medal: '🥉', title: '3rd Place' },
  ] as const
  const placeByName = computed(() => {
    const m: Record<string, any> = {}
    for (const c of champions.value) {
      for (const p of PODIUM) {
        const nm = (c as any)[p.key]
        if (nm && !m[nm]) m[nm] = { rank: p.rank, medal: p.medal, title: p.title, label: c.label, tournamentName: c.name }
      }
    }
    return m
  })

  return { champions, currentChampion, placeByName, loaded, load }
}

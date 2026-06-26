// Tournament data + commissioner actions. Loads the active season's
// tournaments, the "current" one (active > setup > latest), its participants
// and bracket; exposes create / seed / start. Live bracket games are started
// via useLiveMatch().startTournamentMatch and finished via finishMatch.
import type { RealtimeChannel } from '@supabase/supabase-js'
import { ref, computed } from 'vue'

export function useTournaments() {
  const supabase = useSupabase()
  const { accessCode } = useRole()

  const list = ref<any[]>([])
  const current = ref<any | null>(null)
  const participants = ref<any[]>([])
  const bracket = ref<any[]>([])
  const names = ref<Record<string, string>>({})
  const seedPool = ref<any[]>([])     // active players, ELO order, for seeding
  const loading = ref(true)
  const err = ref<string | null>(null)
  const busy = ref(false)
  let channel: RealtimeChannel | null = null

  async function load() {
    const { data: s } = await supabase.rpc('get_public_settings')
    const seasonId = (Array.isArray(s) ? s[0] : s)?.active_season_id
    if (!seasonId) { list.value = []; current.value = null; loading.value = false; return }

    const { data: ts } = await supabase.from('tournaments').select('*').eq('season_id', seasonId).order('created_at', { ascending: false })
    list.value = ts ?? []
    current.value = (ts ?? []).find((t: any) => t.status === 'active')
      ?? (ts ?? []).find((t: any) => t.status === 'setup')
      ?? (ts ?? [])[0] ?? null

    if (current.value) {
      const [{ data: ps }, { data: bm }] = await Promise.all([
        supabase.from('tournament_participants').select('player_id,seed').eq('tournament_id', current.value.id).order('seed'),
        supabase.from('tournament_matches').select('*').eq('tournament_id', current.value.id).order('round').order('position'),
      ])
      participants.value = ps ?? []
      bracket.value = bm ?? []
    } else {
      participants.value = []; bracket.value = []
    }

    const { data: players } = await supabase.from('players').select('id,name')
    names.value = Object.fromEntries((players ?? []).map((p: any) => [p.id, p.name]))
    loading.value = false
  }

  async function loadSeedPool() {
    const { data } = await supabase.from('v_current_standings').select('player_id,name,elo').order('rank')
    seedPool.value = (data ?? []).map((r: any) => ({ id: r.player_id, name: r.name, elo: r.elo }))
  }

  function subscribe() {
    channel = supabase.channel('tournaments')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'tournaments' }, () => load())
      .on('postgres_changes', { event: '*', schema: 'public', table: 'tournament_matches' }, () => load())
      .on('postgres_changes', { event: '*', schema: 'public', table: 'tournament_participants' }, () => load())
      .subscribe()
  }
  function unsubscribe() { if (channel) { supabase.removeChannel(channel); channel = null } }

  // bracket grouped into rounds (columns)
  const rounds = computed(() => {
    const m: Record<number, any[]> = {}
    for (const x of bracket.value) (m[x.round] ??= []).push(x)
    return Object.keys(m).map(Number).sort((a, b) => a - b)
      .map((r) => ({ round: r, matches: m[r].slice().sort((a, b) => a.position - b.position) }))
  })
  const champion = computed(() => {
    if (current.value?.status !== 'completed') return null
    const last = rounds.value[rounds.value.length - 1]?.matches?.[0]
    return last?.winner_id ? (names.value[last.winner_id] ?? null) : null
  })

  async function run(fn: () => PromiseLike<{ error: any }>) {
    if (busy.value) return false
    busy.value = true; err.value = null
    const { error } = await fn()
    if (error) err.value = error.message
    else await load()
    busy.value = false
    return !error
  }

  const createTournament = (name: string, matchType: 'quick' | 'series', seeding: 'elo' | 'manual' | 'random') =>
    run(() => supabase.rpc('create_tournament', { p_code: accessCode.value, p_name: name, p_match_type: matchType, p_seeding_method: seeding }))
  const setSeeds = (tournamentId: string, playerIds: string[]) =>
    run(() => supabase.rpc('set_tournament_seeds', { p_code: accessCode.value, p_tournament_id: tournamentId, p_player_ids: playerIds }))
  const startTournament = (tournamentId: string) =>
    run(() => supabase.rpc('start_tournament', { p_code: accessCode.value, p_tournament_id: tournamentId }))
  // report a bracket result from final scores (ELO-neutral, advances the bracket)
  const reportMatch = (tmId: string, games: { a: number; b: number }[]) =>
    run(() => supabase.rpc('report_tournament_match', { p_code: accessCode.value, p_tm_id: tmId, p_games: games }))

  return {
    list, current, participants, bracket, rounds, champion, names, seedPool, loading, err, busy,
    load, loadSeedPool, subscribe, unsubscribe, createTournament, setSeeds, startTournament, reportMatch,
  }
}

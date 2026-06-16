// Live match state + actions, as a SINGLETON so every surface shares one
// copy: the persistent scoreboard dock in the top bar, the /matches page, and
// the top-bar CTA all read/write the same refs and one Realtime subscription.
//  - The layout owns the lifecycle (load + subscribe once); pages must NOT
//    unsubscribe or they'd kill the shared subscription.
//  - Serve rotation is derived purely from the score (5-each, then 2-each from
//    10-10). ELO is applied server-side only at complete_match.
import type { RealtimeChannel } from '@supabase/supabase-js'
import { ref, computed } from 'vue'

type MatchType = 'quick' | 'series'
type Color = 'blue' | 'yellow'

// ---- shared module-level state (singleton) ----
const match = ref<any | null>(null)
const games = ref<any[]>([])
const points = ref<any[]>([])               // current game's points (timeline)
const names = ref<Record<string, string>>({})
const activePlayers = ref<any[]>([])
const loading = ref(true)
const err = ref<string | null>(null)
const busy = ref(false)
let channel: RealtimeChannel | null = null
let poll: ReturnType<typeof setInterval> | null = null
let started = false

// Serve rotation: true if the FIRST server serves the next point.
export function firstServerServesNext(scoreA: number, scoreB: number): boolean {
  const total = scoreA + scoreB
  const inDeuce = scoreA >= 10 && scoreB >= 10
  const block = inDeuce ? Math.floor((total - 20) / 2) : Math.floor(total / 5)
  return block % 2 === 0
}

export function useLiveMatch() {
  const supabase = useSupabase()
  const { accessCode } = useRole()

  const currentGame = computed(() =>
    games.value.find(g => g.status === 'in_progress') ??
    games.value[games.value.length - 1] ?? null)

  const needed = computed(() => (match.value?.type === 'series' ? 2 : 1))
  const aGamesWon = computed(() => games.value.filter(g => g.winner_id === match.value?.player_a).length)
  const bGamesWon = computed(() => games.value.filter(g => g.winner_id === match.value?.player_b).length)
  const decided = computed(() =>
    !!match.value && (aGamesWon.value >= needed.value || bGamesWon.value >= needed.value))
  const matchWinnerId = computed(() =>
    !decided.value ? null : (aGamesWon.value >= needed.value ? match.value.player_a : match.value.player_b))

  const currentGameDone = computed(() => currentGame.value?.status === 'completed')
  const canStartNextGame = computed(() =>
    !!match.value && currentGameDone.value && !decided.value && games.value.length < match.value.best_of)

  function other(id: string) {
    return id === match.value?.player_a ? match.value?.player_b : match.value?.player_a
  }

  const serverId = computed<string | null>(() => {
    const g = currentGame.value
    if (!g || g.status !== 'in_progress') return null
    return firstServerServesNext(g.score_a, g.score_b) ? g.first_server_id : other(g.first_server_id)
  })

  async function load() {
    try {
      const { data: s } = await supabase.rpc('get_public_settings')
      const cur = (Array.isArray(s) ? s[0] : s)?.current_match_id ?? null
      if (!cur) { match.value = null; games.value = []; points.value = []; return }

      const { data: m, error: me } = await supabase.from('matches').select('*').eq('id', cur).maybeSingle()
      if (me) { err.value = me.message; return }
      if (!m || m.status !== 'in_progress') { match.value = null; games.value = []; points.value = []; return }
      match.value = m

      const { data: g } = await supabase.from('games').select('*').eq('match_id', cur).order('game_number')
      games.value = g ?? []

      const { data: ps } = await supabase.from('players').select('id,name').in('id', [m.player_a, m.player_b])
      names.value = Object.fromEntries((ps ?? []).map((p: any) => [p.id, p.name]))

      // current game's points, for the officiate timeline
      const cg = (g ?? []).find((x: any) => x.status === 'in_progress') ?? (g ?? [])[(g ?? []).length - 1] ?? null
      if (cg) {
        const { data: pts } = await supabase.from('points')
          .select('id,point_number,scorer_id,server_id').eq('game_id', cg.id).order('point_number')
        points.value = pts ?? []
      } else {
        points.value = []
      }
    } finally {
      loading.value = false
    }
  }

  async function loadActivePlayers() {
    const { data } = await supabase.from('players').select('id,name').eq('is_active', true).order('name')
    activePlayers.value = data ?? []
  }

  // call once, client-side, from the layout
  function start() {
    if (started || !import.meta.client) return
    started = true
    load()
    channel = supabase
      .channel('live-match')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'app_settings' }, () => load())
      .on('postgres_changes', { event: '*', schema: 'public', table: 'matches' }, () => load())
      .on('postgres_changes', { event: '*', schema: 'public', table: 'games' }, () => load())
      .on('postgres_changes', { event: '*', schema: 'public', table: 'points' }, () => load())
      .subscribe()
    poll = setInterval(load, 10000)   // backstop so it settles after a match ends
  }

  async function run(fn: () => PromiseLike<{ error: any }>) {
    if (busy.value) return false
    busy.value = true; err.value = null
    const { error } = await fn()
    if (error) err.value = error.message
    else await load()
    busy.value = false
    return !error
  }

  const startMatch = (p: {
    playerA: string; playerB: string; type: MatchType; firstServer: string; colorA: Color; colorB: Color
  }) => run(() => supabase.rpc('start_match', {
    p_code: accessCode.value, p_player_a: p.playerA, p_player_b: p.playerB,
    p_type: p.type, p_first_server: p.firstServer, p_color_a: p.colorA, p_color_b: p.colorB,
  }))

  const scorePoint = (scorerId: string) => {
    const g = currentGame.value
    if (!g || g.status !== 'in_progress' || !serverId.value) return Promise.resolve(false)
    return run(() => supabase.rpc('add_point', {
      p_code: accessCode.value, p_game_id: g.id, p_server: serverId.value, p_scorer: scorerId,
    }))
  }

  const undo = () => {
    const g = currentGame.value
    if (!g) return Promise.resolve(false)
    return run(() => supabase.rpc('remove_last_point', { p_code: accessCode.value, p_game_id: g.id }))
  }

  const flipPoint = (pointId: string) =>
    run(() => supabase.rpc('flip_point', { p_code: accessCode.value, p_point_id: pointId }))

  const flipServer = () => {
    const g = currentGame.value
    if (!g) return Promise.resolve(false)
    return run(() => supabase.rpc('flip_first_server', { p_code: accessCode.value, p_game_id: g.id }))
  }

  const startNextGame = (firstServer: string) =>
    run(() => supabase.rpc('start_game', { p_code: accessCode.value, p_match_id: match.value.id, p_first_server: firstServer }))

  const finishMatch = () => {
    if (!match.value) return Promise.resolve(false)
    // tournament games are ELO-neutral -> a different finalizer
    const rpc = match.value.tournament_match_id ? 'complete_tournament_match' : 'complete_match'
    return run(() => supabase.rpc(rpc, { p_code: accessCode.value, p_match_id: match.value.id }))
  }

  const cancelMatch = (reason: string) =>
    run(() => supabase.rpc('cancel_match', { p_code: accessCode.value, p_match_id: match.value.id, p_reason: reason }))

  const startTournamentMatch = (p: { tmatchId: string; firstServer: string; colorA: Color; colorB: Color }) =>
    run(() => supabase.rpc('start_tournament_match', {
      p_code: accessCode.value, p_tournament_match_id: p.tmatchId, p_first_server: p.firstServer,
      p_color_a: p.colorA, p_color_b: p.colorB,
    }))

  async function recordQuickResult(p: {
    playerA: string; playerB: string; type: MatchType
    games: { a: number; b: number }[]; colorA: Color; colorB: Color
  }) {
    if (busy.value) return false
    busy.value = true; err.value = null
    try {
      const { data: m, error: e1 } = await supabase.rpc('start_match', {
        p_code: accessCode.value, p_player_a: p.playerA, p_player_b: p.playerB,
        p_type: p.type, p_first_server: p.playerA, p_color_a: p.colorA, p_color_b: p.colorB,
      })
      if (e1) throw e1
      const mid = Array.isArray(m) ? m[0].id : m.id
      let n = 1
      for (const g of p.games) {
        const { error: e2 } = await supabase.rpc('submit_game_score', {
          p_code: accessCode.value, p_match_id: mid, p_game_number: n, p_score_a: g.a, p_score_b: g.b,
        })
        if (e2) throw e2
        n++
      }
      const { error: e3 } = await supabase.rpc('complete_match', { p_code: accessCode.value, p_match_id: mid })
      if (e3) throw e3
      return true
    } catch (e: any) {
      err.value = e.message ?? String(e); return false
    } finally {
      busy.value = false; await load()
    }
  }

  return {
    // state
    match, games, points, names, activePlayers, loading, err, busy,
    // derived
    currentGame, serverId, aGamesWon, bGamesWon, needed, decided, matchWinnerId,
    currentGameDone, canStartNextGame, other,
    // lifecycle
    load, loadActivePlayers, start,
    // actions
    startMatch, scorePoint, undo, flipPoint, flipServer, startNextGame, finishMatch, cancelMatch, recordQuickResult, startTournamentMatch,
  }
}

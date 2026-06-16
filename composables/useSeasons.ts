// Season management for the commissioner: load seasons, start a new season
// (create -> set levers -> activate), edit a season's levers, and end the
// current season (archive + retire all players). Plus read-only archive
// standings for past seasons.
import { ref, computed } from 'vue'

// shape of the lever form shared by start + edit
export interface SeasonForm {
  name: string
  start_date: string | null
  end_date: string | null
  start_rating: number
  elo_floor: number | null
  k_stable: number
  k_swingy: number
  swingy_after_days: number
  k_override: number | null
  mov_enabled: boolean
  mov_weight: number
  mov_cap: number
  mov_formula_stable: 'ratio' | 'log'
  mov_formula_swingy: 'ratio' | 'log'
}

export function defaultSeasonForm(): SeasonForm {
  return {
    name: '', start_date: null, end_date: null,
    start_rating: 1000, elo_floor: 1000,
    k_stable: 20, k_swingy: 40, swingy_after_days: 7, k_override: null,
    mov_enabled: true, mov_weight: 0.5, mov_cap: 1.75,
    mov_formula_stable: 'ratio', mov_formula_swingy: 'log',
  }
}

export function formFromSeason(s: any): SeasonForm {
  return {
    name: s.name, start_date: s.start_date, end_date: s.end_date,
    start_rating: s.start_rating, elo_floor: s.elo_floor,
    k_stable: s.k_stable, k_swingy: s.k_swingy, swingy_after_days: s.swingy_after_days, k_override: s.k_override,
    mov_enabled: s.mov_enabled, mov_weight: s.mov_weight, mov_cap: s.mov_cap,
    mov_formula_stable: s.mov_formula_stable, mov_formula_swingy: s.mov_formula_swingy,
  }
}

// map the form to set_season_config's params
function configParams(code: string, seasonId: string, f: SeasonForm) {
  return {
    p_code: code, p_season_id: seasonId,
    p_name: f.name, p_start_date: f.start_date, p_end_date: f.end_date,
    p_start_rating: f.start_rating, p_elo_floor: f.elo_floor,
    p_k_stable: f.k_stable, p_k_swingy: f.k_swingy, p_swingy_after_days: f.swingy_after_days, p_k_override: f.k_override,
    p_mov_enabled: f.mov_enabled, p_mov_weight: f.mov_weight, p_mov_cap: f.mov_cap,
    p_mov_formula_stable: f.mov_formula_stable, p_mov_formula_swingy: f.mov_formula_swingy,
  }
}

export function useSeasons() {
  const supabase = useSupabase()
  const { accessCode } = useRole()

  const seasons = ref<any[]>([])
  const loading = ref(true)
  const err = ref<string | null>(null)
  const busy = ref(false)

  const active = computed(() => seasons.value.find((s) => s.status === 'active') ?? null)
  const archived = computed(() => seasons.value.filter((s) => s.status === 'archived'))
  const activePlayerCount = ref(0)

  async function load() {
    const [{ data, error }, { count }] = await Promise.all([
      supabase.from('seasons').select('*').order('created_at', { ascending: false }),
      supabase.from('players').select('id', { count: 'exact', head: true }).eq('is_active', true),
    ])
    if (error) err.value = error.message
    else seasons.value = data ?? []
    activePlayerCount.value = count ?? 0
    loading.value = false
  }

  // final standings of an archived season (frozen final_rank)
  async function archiveStandings(seasonId: string) {
    const { data } = await supabase
      .from('player_season_stats')
      .select('final_rank,elo,peak_elo,wins,losses,player_id,players(name)')
      .eq('season_id', seasonId)
      .order('final_rank', { ascending: true })
    return (data ?? []).map((r: any) => ({
      final_rank: r.final_rank, elo: r.elo, peak_elo: r.peak_elo,
      wins: r.wins, losses: r.losses, name: r.players?.name ?? '—',
    }))
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

  // start a new season: create -> set full levers -> activate (one action)
  async function startSeason(f: SeasonForm) {
    if (busy.value) return false
    busy.value = true; err.value = null
    try {
      const { data: created, error: e1 } = await supabase.rpc('create_season', {
        p_code: accessCode.value, p_name: f.name, p_start: f.start_date, p_end: f.end_date, p_elo_floor: f.elo_floor,
      })
      if (e1) throw e1
      const sid = Array.isArray(created) ? created[0].id : created.id
      const { error: e2 } = await supabase.rpc('set_season_config', configParams(accessCode.value, sid, f))
      if (e2) throw e2
      const { error: e3 } = await supabase.rpc('activate_season', { p_code: accessCode.value, p_season_id: sid })
      if (e3) throw e3
      return true
    } catch (e: any) {
      err.value = e.message ?? String(e); return false
    } finally {
      busy.value = false; await load()
    }
  }

  const saveConfig = (seasonId: string, f: SeasonForm) =>
    run(() => supabase.rpc('set_season_config', configParams(accessCode.value, seasonId, f)))

  const endSeason = () =>
    run(() => supabase.rpc('end_season', { p_code: accessCode.value }))

  return {
    seasons, active, archived, activePlayerCount, loading, err, busy,
    load, archiveStandings, startSeason, saveConfig, endSeason,
  }
}

<script setup lang="ts">
// Full leaderboard — live standings for the active season from
// v_current_standings, with Realtime: any change to player_season_stats
// (a completed match updating ELO/record) re-pulls the table across devices.
import type { RealtimeChannel } from '@supabase/supabase-js'

const supabase = useSupabase()
const standings = ref<any[]>([])
const loading = ref(true)
const err = ref<string | null>(null)
const lastPair = ref<string[]>([])   // the two players from the most recent completed match
let channel: RealtimeChannel | null = null

async function load() {
  const { data, error } = await supabase
    .from('v_current_standings')
    .select('*')
    .order('rank')
  if (error) err.value = error.message
  else { standings.value = data ?? []; err.value = null }

  // highlight the two players from the most recent completed match this season
  const seasonId = (data ?? [])[0]?.season_id
  if (seasonId) {
    const { data: last } = await supabase
      .from('matches')
      .select('player_a,player_b')
      .eq('status', 'completed').eq('season_id', seasonId)
      .order('completed_at', { ascending: false }).limit(1).maybeSingle()
    lastPair.value = last ? [last.player_a, last.player_b] : []
  } else {
    lastPair.value = []
  }
  loading.value = false
}

function streakLabel(s: number) {
  return s > 0 ? `W${s}` : s < 0 ? `L${-s}` : '—'
}

onMounted(() => {
  load()
  channel = supabase
    .channel('standings')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'player_season_stats' }, () => load())
    .on('postgres_changes', { event: '*', schema: 'public', table: 'matches' }, () => load())
    .subscribe()
})

onUnmounted(() => {
  if (channel) supabase.removeChannel(channel)
})
</script>

<template>
  <section>
    <h1 class="display page-title">Leaderboard</h1>

    <p v-if="loading" class="muted">Loading standings…</p>
    <p v-else-if="err" class="err">Couldn't load: {{ err }}</p>
    <p v-else-if="!standings.length" class="muted">
      No players yet — add players and activate a season (see setup runbook).
    </p>

    <div v-else class="card table">
      <div class="row head">
        <span>#</span>
        <span>Player</span>
        <span class="mono num">ELO</span>
        <span class="mono num">W–L</span>
        <span class="mono num wide">Games</span>
        <span class="mono num wide">Pts±</span>
        <span class="mono num">Streak</span>
      </div>
      <div v-for="p in standings" :key="p.player_id" class="row" :class="{ recent: lastPair.includes(p.player_id) }">
        <span class="mono rank">{{ p.rank }}</span>
        <span class="name">{{ p.name }}</span>
        <span class="mono num elo" :title="`Peak ELO: ${p.peak_elo}`">{{ p.elo }}</span>
        <span class="mono num">{{ p.wins }}–{{ p.losses }}</span>
        <span class="mono num wide muted">{{ p.games_won }}–{{ p.games_lost }}</span>
        <span
          class="mono num wide"
          :class="{ pos: p.points_for - p.points_against > 0, neg: p.points_for - p.points_against < 0 }"
        >{{ p.points_for - p.points_against > 0 ? '+' : '' }}{{ p.points_for - p.points_against }}</span>
        <span class="mono num" :class="{ pos: p.current_streak > 0, neg: p.current_streak < 0 }">
          {{ streakLabel(p.current_streak) }}
        </span>
      </div>
    </div>
  </section>
</template>

<style scoped>
.page-title { font-size: 2rem; margin: 0 0 1rem; }
.muted { color: var(--muted); }
.err { color: var(--bad); }
.table { overflow: hidden; }
.row {
  display: grid;
  grid-template-columns: 2.5rem 1fr 4rem 4.5rem 5rem 4.5rem 4.5rem;
  align-items: center; gap: .5rem; padding: .8rem 1rem; border-bottom: 1px solid var(--line);
}
.row:last-child { border-bottom: 0; }
.head { color: var(--faint); font-size: .78rem; text-transform: uppercase; letter-spacing: .05em; }
.num { text-align: right; }
.head .num { text-align: right; }
.name { font-weight: 600; }
.elo { color: var(--yellow); font-weight: 600; cursor: help; }
.rank { color: var(--muted); }
.pos { color: var(--good); }
.neg { color: var(--bad); }
/* the two players from the most recent match — a soft glow */
.row.recent { background: rgba(255, 203, 45, .07); animation: recent-glow 2.4s ease-in-out infinite; }
@keyframes recent-glow {
  0%, 100% { box-shadow: inset 3px 0 0 0 var(--yellow); }
  50% { box-shadow: inset 3px 0 0 0 var(--yellow), 0 0 16px -7px var(--yellow); }
}

/* On narrow screens keep the essentials: #, Player, ELO, W–L, Streak */
@media (max-width: 640px) {
  .row { grid-template-columns: 2.2rem 1fr 4rem 4.5rem 4.5rem; }
  .wide { display: none; }
}
</style>

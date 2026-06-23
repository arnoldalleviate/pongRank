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

// Season infographics (live) + curated midseason titles (re-awarded at season's end).
const recap = useSeasonRecap()
const { stats: recapStats } = recap
const AWARDS = [
  { emoji: '🛋️', title: 'No-Lifer',     player: 'Joey',     context: '20 matches logged. We’ve stopped asking if Joey has a job, a family — the table is home now.' },
  { emoji: '⚔️', title: 'Giant Slayer', player: 'Alec',     context: 'Walked up to the giant in the room (1133) and chopped them down. David had a sling; Alec had a paddle.' },
  { emoji: '🪓', title: 'Berserker',    player: 'Evan',     context: 'Hurled himself at the toughest opponents and went down swinging. No fear, no defense, no survivors — himself included.' },
  { emoji: '🐎', title: 'Dark Horse',   player: 'Jayden',   context: 'Games came down to the final points. Nobody’s safe when Jayden is playing.' },
  { emoji: '🤺', title: 'The Duelist',  player: 'Erin',     context: '4-4, and somehow every one was a shootout to the last point. Do you feel lucky?' },
  { emoji: '🐴', title: 'Work Horse',   player: 'Justin J', context: 'Took the hardest schedule in the league and just kept showing up. Respect the grind.' },
  { emoji: '😴', title: 'The Sleeper',  player: 'Austin',   context: 'The Sleeper’s about to wake up.' },
]
const titleByName = Object.fromEntries(AWARDS.map((a) => [a.player, a]))

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

// Players who've logged a match are ranked; 0-game players sit on the Bench
// (so a still-at-start player can't appear to outrank someone who's played).
const played = computed(() => standings.value.filter((p: any) => p.matches_played > 0))
const bench = computed(() =>
  standings.value.filter((p: any) => !p.matches_played)
    .slice().sort((a: any, b: any) => a.name.localeCompare(b.name)),
)

onMounted(() => {
  load()
  recap.load()
  channel = supabase
    .channel('standings')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'player_season_stats' }, () => load())
    .on('postgres_changes', { event: '*', schema: 'public', table: 'matches' }, () => { load(); recap.load() })
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

    <template v-else>
      <div v-if="played.length" class="card table">
        <div class="row head">
          <span>#</span>
          <span>Player</span>
          <span class="mono num">ELO</span>
          <span class="mono num">W–L</span>
          <span class="mono num wide">Games</span>
          <span class="mono num wide">Pts±</span>
          <span class="mono num">Streak</span>
        </div>
        <div v-for="(p, i) in played" :key="p.player_id" class="row" :class="{ recent: lastPair.includes(p.player_id) }">
          <span class="mono rank">{{ i + 1 }}</span>
          <span class="name">
            <span class="nm-text">{{ p.name }}</span>
            <span v-if="titleByName[p.name]" class="flair" :title="titleByName[p.name].title">
              <span class="fl-emoji">{{ titleByName[p.name].emoji }}</span><span class="fl-title">{{ titleByName[p.name].title }}</span>
            </span>
          </span>
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
      <p v-else class="muted">No matches played yet this season — everyone's on the bench.</p>

      <!-- Bench: players with 0 logged games, unranked until they play -->
      <section v-if="bench.length" class="bench">
        <h2 class="bench-h">Bench <span class="bench-count">{{ bench.length }} · awaiting first match</span></h2>
        <div class="card bench-list">
          <span v-for="p in bench" :key="p.player_id" class="bench-chip">{{ p.name }}</span>
        </div>
      </section>

      <!-- Season recap: live infographics + curated midseason titles -->
      <section v-if="recapStats && recapStats.matches" class="recap">
        <h2 class="recap-h display">Season 0 · Midseason Recap</h2>
        <div class="ig-grid">
          <div class="ig"><span class="ig-num mono">{{ recapStats.matches }}</span><span class="ig-lbl">Matches</span></div>
          <div class="ig"><span class="ig-num mono">{{ recapStats.games }}</span><span class="ig-lbl">Games</span></div>
          <div class="ig"><span class="ig-num mono">{{ recapStats.points }}</span><span class="ig-lbl">Points scored</span></div>
          <div class="ig"><span class="ig-num mono">{{ recapStats.closePct }}%</span><span class="ig-lbl">Nail-biters (≤3)</span></div>
          <div class="ig"><span class="ig-num mono">{{ recapStats.avg }}</span><span class="ig-lbl">Avg pts / game</span></div>
          <div class="ig"><span class="ig-num mono">{{ recapStats.highGame }}</span><span class="ig-lbl">Highest-scoring game</span></div>
        </div>

        <div class="award card finale">
          <span class="aw-emoji">🏓</span>
          <div class="aw-body">
            <div class="aw-top"><span class="aw-title">Thanks for playing!</span></div>
            <p class="aw-context">Season 0 has been a blast — every blowout, every deuce, every upset. The wild second half starts now, and the board is about to get chaotic. Know someone who’d love this? <strong>Bring a friend into the league and help us clear the bench.</strong> 🏓</p>
          </div>
        </div>

        <h3 class="awards-h">🏅 Titles <span class="awards-sub">· midseason — re-awarded at season’s end</span></h3>
        <div class="awards">
          <div v-for="a in AWARDS" :key="a.title" class="award card">
            <span class="aw-emoji">{{ a.emoji }}</span>
            <div class="aw-body">
              <div class="aw-top"><span class="aw-title">{{ a.title }}</span><span class="aw-player">{{ a.player }}</span></div>
              <p class="aw-context">{{ a.context }}</p>
            </div>
          </div>
        </div>
      </section>
    </template>
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
.name { font-weight: 600; min-width: 0; display: flex; align-items: center; gap: .45rem; }
.nm-text { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.flair {
  flex: none; display: inline-flex; align-items: center; gap: .25rem;
  font-size: .64rem; font-weight: 700; text-transform: uppercase; letter-spacing: .03em;
  color: var(--yellow); background: rgba(255, 203, 45, .12);
  border: 1px solid var(--yellow-deep); border-radius: 999px; padding: .12rem .5rem;
}
.fl-emoji { font-size: .8rem; }
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

/* Bench — 0-game players, no rank/stats shown (just names) */
.bench { margin-top: 1.5rem; }
.bench-h { font-size: 1rem; text-transform: uppercase; letter-spacing: .05em; color: var(--muted); margin: 0 0 .6rem; display: flex; align-items: baseline; gap: .5rem; flex-wrap: wrap; }
.bench-count { font-size: .72rem; color: var(--faint); font-weight: 400; letter-spacing: .03em; text-transform: none; }
.bench-list { display: flex; flex-wrap: wrap; gap: .5rem; padding: 1rem; }
.bench-chip { background: var(--surface-2); border: 1px solid var(--line); border-radius: 999px; padding: .3rem .75rem; font-size: .85rem; color: var(--muted); }

/* Season recap — infographics + titles */
.recap { margin-top: 2rem; }
.recap-h { font-size: 1.15rem; margin: 0 0 .9rem; color: var(--ink); }
.ig-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(8.5rem, 1fr)); gap: .6rem; margin-bottom: 1.75rem; }
.ig {
  display: flex; flex-direction: column; gap: .25rem; align-items: center; justify-content: center;
  background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius-sm); padding: 1rem .6rem; text-align: center;
}
.ig-num { font-size: 1.6rem; font-weight: 700; color: var(--yellow); line-height: 1; }
.ig-lbl { font-size: .72rem; text-transform: uppercase; letter-spacing: .04em; color: var(--faint); }

.awards-h { font-size: 1rem; margin: 0 0 .75rem; color: var(--muted); }
.awards-sub { font-size: .72rem; color: var(--faint); font-weight: 400; }
.awards { display: grid; grid-template-columns: repeat(auto-fill, minmax(15rem, 1fr)); gap: .7rem; }
.award { display: flex; gap: .75rem; padding: .9rem 1rem; align-items: flex-start; }
.aw-emoji { font-size: 1.6rem; line-height: 1; flex: none; }
.aw-body { min-width: 0; }
.aw-top { display: flex; align-items: baseline; gap: .5rem; flex-wrap: wrap; margin-bottom: .3rem; }
.aw-title { font-family: var(--font-display); text-transform: uppercase; letter-spacing: .03em; color: var(--yellow); font-size: 1rem; }
.aw-player { font-weight: 700; color: var(--ink); font-size: .9rem; }
.aw-context { margin: 0; font-size: .82rem; color: var(--muted); line-height: 1.4; }
.finale { margin: 0 0 1.75rem; align-items: center; border-left: 3px solid var(--yellow); background: rgba(255, 203, 45, .06); }
.finale .aw-context { color: var(--ink); }
.finale strong { color: var(--yellow); }

/* On narrow screens keep the essentials: #, Player, ELO, W–L, Streak */
@media (max-width: 640px) {
  .row {
    grid-template-columns: 1.5rem 1fr 3rem 3.4rem 2.6rem;
    gap: .4rem; padding: .8rem .7rem;
  }
  .wide { display: none; }
  .head > span:first-child, .rank { text-align: center; }   /* re-center the rank column */
  .flair .fl-title { display: none; }                        /* emoji-only badge on phones */
  .flair { padding: .1rem .3rem; }
}
</style>

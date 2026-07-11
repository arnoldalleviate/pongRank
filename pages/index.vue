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

// Commissioner announcement (live). Season 0's recap is archived below as a frozen snapshot.
const recap = useSeasonRecap()
const { note: commishNote, noteUrl: commishUrl } = recap
// Permanent tournament-champion badge (🏆) — derived from all completed
// tournaments, so it persists on the winner's row across season resets.
// currentChampion additionally drives the LOUD reigning-champion row treatment
// (big "S0" watermark + gold wash), which self-retires when the season flips.
const { currentChampion, placeByName, load: loadChampion } = useChampion()
const champName = computed(() => currentChampion.value?.championName ?? null)
// Tiled "S0" watermark for the reigning champion's nameplate — a repeating SVG
// pattern (two staggered instances per tile = seamless brick repeat).
const platePattern = computed(() => {
  const label = currentChampion.value?.label || 'S0'
  const svg =
    `<svg xmlns='http://www.w3.org/2000/svg' width='58' height='34'>` +
    `<g font-family='Arial Black, Arial, sans-serif' font-weight='900' font-size='12' letter-spacing='0.5' fill='#FFCB2D' fill-opacity='0.15'>` +
    `<text x='4' y='13'>${label}</text>` +
    `<text x='33' y='30'>${label}</text>` +
    `</g></svg>`
  return `url("data:image/svg+xml,${encodeURIComponent(svg)}")`
})
// Season 0 final recap — FROZEN snapshot (archived; no longer computed live).
const SEASON0_RECAP = { matches: 55, games: 131, points: 2376, closePct: 47, avg: '18.1', highGame: '22–20' }

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

// Ranked = anyone who's logged a match OR been manually rated off the 1000
// start (lets featured/exec players show on the board even at 0-0). A 0-game
// player still sitting at the 1000 start stays on the Bench.
const played = computed(() => standings.value.filter((p: any) => p.matches_played > 0 || p.elo !== 1000))
const bench = computed(() =>
  standings.value.filter((p: any) => !p.matches_played && p.elo === 1000)
    .slice().sort((a: any, b: any) => a.name.localeCompare(b.name)),
)

onMounted(() => {
  load()
  recap.load()
  loadChampion()
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

    <div v-if="commishNote" class="commish-note">
      <span class="commish-badge">📣 Commissioner</span>
      <span class="commish-text">{{ commishNote }}
        <a v-if="commishUrl" :href="commishUrl" target="_blank" rel="noopener" class="commish-link">Details →</a>
      </span>
    </div>

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
          <span
            class="name"
            :class="{ 'name-champ': p.name === champName }"
            :style="p.name === champName ? { backgroundImage: platePattern } : null"
          >
            <span class="nm-text">{{ p.name }}</span>
            <span
              v-if="placeByName[p.name]"
              class="place-badge"
              :class="`rank${placeByName[p.name].rank}`"
              :title="`${placeByName[p.name].tournamentName} ${placeByName[p.name].title}`"
            >
              <span class="pb-emoji">{{ placeByName[p.name].medal }}</span><span class="pb-label">{{ placeByName[p.name].label }}</span>
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

      <!-- Season 0 archive — frozen recap snapshot, stashed in a collapsible dropdown -->
      <details class="s0-archive">
        <summary class="s0-summary">
          <span class="s0-chip">Season 0</span>
          <span class="s0-sub">Final recap</span>
        </summary>
        <div class="ig-grid">
          <div class="ig"><span class="ig-num mono">{{ SEASON0_RECAP.matches }}</span><span class="ig-lbl">Matches</span></div>
          <div class="ig"><span class="ig-num mono">{{ SEASON0_RECAP.games }}</span><span class="ig-lbl">Games</span></div>
          <div class="ig"><span class="ig-num mono">{{ SEASON0_RECAP.points }}</span><span class="ig-lbl">Points scored</span></div>
          <div class="ig"><span class="ig-num mono">{{ SEASON0_RECAP.closePct }}%</span><span class="ig-lbl">Nail-biters (≤3)</span></div>
          <div class="ig"><span class="ig-num mono">{{ SEASON0_RECAP.avg }}</span><span class="ig-lbl">Avg pts / game</span></div>
          <div class="ig"><span class="ig-num mono">{{ SEASON0_RECAP.highGame }}</span><span class="ig-lbl">Highest-scoring game</span></div>
        </div>

        <div class="award card finale">
          <span class="aw-emoji">🏓</span>
          <div class="aw-body">
            <div class="aw-top"><span class="aw-title">Thanks for playing!</span></div>
            <p class="aw-context">Season 0 was a blast — every blowout, every deuce, every upset. Know someone who’d love this? <strong>Bring a friend into the league and help us clear the bench.</strong> 🏓</p>
          </div>
        </div>
      </details>
    </template>
  </section>
</template>

<style scoped>
.page-title { font-size: 2rem; margin: 0 0 1rem; }
.muted { color: var(--muted); }
.err { color: var(--bad); }

/* commissioner announcement banner (mirrors the match-log one) */
.commish-note {
  display: flex; gap: .6rem; align-items: baseline; flex-wrap: wrap;
  background: rgba(255, 203, 45, .07); border: 1px solid var(--line);
  border-left: 3px solid var(--yellow); border-radius: var(--radius-sm);
  padding: .7rem .9rem; margin-bottom: 1.25rem; font-size: .9rem; color: var(--ink);
}
.commish-badge { font-size: .66rem; font-weight: 800; text-transform: uppercase; letter-spacing: .05em; color: var(--yellow-deep); white-space: nowrap; }
.commish-text { flex: 1; min-width: 12rem; }
.commish-link { color: var(--yellow); font-weight: 700; text-decoration: none; white-space: nowrap; }
.commish-link:hover { text-decoration: underline; }

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
/* permanent podium badge — gold/silver/bronze fill */
.place-badge {
  flex: none; display: inline-flex; align-items: center; gap: .25rem; cursor: help;
  font-size: .64rem; font-weight: 800; text-transform: uppercase; letter-spacing: .04em;
  border: 1px solid; border-radius: 999px; padding: .12rem .5rem;
}
.place-badge.rank1 { background: var(--yellow); border-color: var(--yellow-deep); color: #1a1300; }
.place-badge.rank2 { background: #cfd3d9; border-color: #9aa0a8; color: #1c2026; }
.place-badge.rank3 { background: #d69a6e; border-color: #a9663a; color: #2a1608; }
.pb-emoji { font-size: .8rem; }
/* reigning champion's nameplate — tiled "S0" watermark (bg image set inline),
   gold-engraved plate. Loud, current-season only; retires with the season. */
.name-champ {
  padding: .25rem .5rem; margin: -.25rem 0;   /* room for the tile, same row height */
  background-repeat: repeat;                    /* gentle tiled "S0" lettering only, no fill */
}
.name-champ .nm-text { color: var(--yellow); font-weight: 800; }
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

/* Season 0 archive — frozen recap in a collapsible dropdown */
.s0-archive { margin-top: 2rem; border: 1px solid var(--line); border-radius: var(--radius-sm); background: var(--surface); overflow: hidden; }
.s0-summary { cursor: pointer; list-style: none; display: flex; align-items: center; gap: .6rem; padding: .9rem 1.1rem; }
.s0-summary::-webkit-details-marker { display: none; }
.s0-summary::after { content: '▸'; margin-left: auto; color: var(--faint); transition: transform .15s ease; }
.s0-archive[open] .s0-summary { border-bottom: 1px solid var(--line); }
.s0-archive[open] .s0-summary::after { transform: rotate(90deg); }
.s0-chip { font-family: var(--font-display); text-transform: uppercase; letter-spacing: .04em; color: var(--yellow); font-size: 1rem; }
.s0-sub { font-size: .78rem; color: var(--faint); }
.ig-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(8.5rem, 1fr)); gap: .6rem; margin: 1rem; }
.ig {
  display: flex; flex-direction: column; gap: .25rem; align-items: center; justify-content: center;
  background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius-sm); padding: 1rem .6rem; text-align: center;
}
.ig-num { font-size: 1.6rem; font-weight: 700; color: var(--yellow); line-height: 1; }
.ig-lbl { font-size: .72rem; text-transform: uppercase; letter-spacing: .04em; color: var(--faint); }

.award { display: flex; gap: .75rem; padding: .9rem 1rem; align-items: flex-start; }
.aw-emoji { font-size: 1.6rem; line-height: 1; flex: none; }
.aw-body { min-width: 0; }
.aw-top { display: flex; align-items: baseline; gap: .5rem; flex-wrap: wrap; margin-bottom: .3rem; }
.aw-title { font-family: var(--font-display); text-transform: uppercase; letter-spacing: .03em; color: var(--yellow); font-size: 1rem; }
.aw-context { margin: 0; font-size: .82rem; color: var(--muted); line-height: 1.4; }
.finale { margin: 0 1rem 1rem; align-items: center; border-left: 3px solid var(--yellow); background: rgba(255, 203, 45, .06); }
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
  .place-badge .pb-label { display: none; }                  /* medal-only badge on phones */
  .place-badge { padding: .1rem .3rem; }
}
</style>

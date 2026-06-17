<script setup lang="ts">
// Officiate dashboard — the place to score and edit a live match.
//  - big tap panels add a point to blue / yellow
//  - serve possession is shown (🏓) and tracked automatically
//  - the game timeline shows every point as a blue/yellow box; officials tap a
//    box to flip who scored it (fixes mis-taps)
//  - undo / next game / finish / cancel
// Read-only for viewers (they can watch the dashboard live).
import { ref, computed, onMounted } from 'vue'

const { isOfficial } = useRole()
const lm = useLiveMatch()
const {
  match, names, points, currentGame, serverId, aGamesWon, bGamesWon,
  decided, matchWinnerId, currentGameDone, canStartNextGame, busy, err,
} = lm

onMounted(() => lm.load())   // layout owns the live subscription

const blueId = computed(() => !match.value ? null : (match.value.color_a === 'blue' ? match.value.player_a : match.value.player_b))
const yellowId = computed(() => !match.value ? null : (match.value.color_a === 'blue' ? match.value.player_b : match.value.player_a))
const blueName = computed(() => (blueId.value && names.value[blueId.value]) || 'Blue')
const yellowName = computed(() => (yellowId.value && names.value[yellowId.value]) || 'Yellow')
const blueScore = computed(() => { const g = currentGame.value; return g && match.value ? (match.value.color_a === 'blue' ? g.score_a : g.score_b) : 0 })
const yellowScore = computed(() => { const g = currentGame.value; return g && match.value ? (match.value.color_a === 'blue' ? g.score_b : g.score_a) : 0 })
const blueGames = computed(() => match.value?.color_a === 'blue' ? aGamesWon.value : bGamesWon.value)
const yellowGames = computed(() => match.value?.color_a === 'blue' ? bGamesWon.value : aGamesWon.value)
const servingBlue = computed(() => !!serverId.value && serverId.value === blueId.value)
const servingYellow = computed(() => !!serverId.value && serverId.value === yellowId.value)
const winnerName = computed(() => (matchWinnerId.value && names.value[matchWinnerId.value]) || '')

const canScore = computed(() => isOfficial.value && currentGame.value?.status === 'in_progress' && !decided.value)
const canEdit = computed(() => isOfficial.value && !!match.value)   // flip allowed while match is live
const isTournament = computed(() => !!match.value?.tournament_match_id)
const canFlipServer = computed(() =>
  isOfficial.value && currentGame.value?.status === 'in_progress'
  && ((currentGame.value?.score_a ?? 0) + (currentGame.value?.score_b ?? 0)) <= 5)
function scoredByBlue(p: any) { return p.scorer_id === blueId.value }

// group points into blocks of 5 to visualise the serve rotation (server
// switches every 5; blue serves the first block, so colour labels aren't needed)
const pointGroups = computed(() => {
  const groups: any[][] = []
  for (let i = 0; i < points.value.length; i += 5) groups.push(points.value.slice(i, i + 5))
  return groups
})

const showCancel = ref(false)
const cancelReason = ref('')
async function doCancel() {
  const ok = await lm.cancelMatch(cancelReason.value)
  if (ok) { showCancel.value = false; cancelReason.value = ''; navigateTo('/matches') }
}

async function doFinish() {
  const tourney = !!match.value?.tournament_match_id
  const ok = await lm.finishMatch()
  if (ok) navigateTo(tourney ? '/tournaments' : '/')   // bracket for tournaments, else leaderboard
}
</script>

<template>
  <section>
    <h1 class="display page-title">Officiate</h1>
    <p v-if="err" class="err">{{ err }}</p>

    <!-- no live match -->
    <div v-if="!match" class="card empty">
      <p class="muted big">No match in progress.</p>
      <NuxtLink v-if="isOfficial" to="/matches" class="btn btn-yellow">Create a match</NuxtLink>
      <p v-else class="muted">An official starts a match from “Create match”.</p>
    </div>

    <template v-else>
      <div class="meta">
        <span class="pill">{{ match.type === 'series' ? 'Best of 3' : 'Quick' }}</span>
        <span class="mono muted">Game {{ currentGame?.game_number }}</span>
        <span v-if="match.type === 'series'" class="mono games">Games {{ blueGames }}–{{ yellowGames }}</span>
        <span v-if="!isOfficial" class="mono muted view">view only</span>
      </div>

      <!-- tap-to-score panels -->
      <div class="panels">
        <button class="panel blue" :class="{ serving: servingBlue, tappable: canScore }"
                :disabled="!canScore || busy" @click="canScore && lm.scorePoint(blueId)">
          <Confetti v-if="decided && matchWinnerId === blueId" mode="burst" />
          <span class="p-serve" :class="{ on: servingBlue }">🏓 serving</span>
          <span class="p-name">{{ blueName }}</span>
          <span class="p-score display">{{ blueScore }}</span>
          <span class="p-add" :class="{ show: canScore }">＋ point</span>
        </button>
        <button class="panel yellow" :class="{ serving: servingYellow, tappable: canScore }"
                :disabled="!canScore || busy" @click="canScore && lm.scorePoint(yellowId)">
          <Confetti v-if="decided && matchWinnerId === yellowId" mode="burst" />
          <span class="p-serve" :class="{ on: servingYellow }">🏓 serving</span>
          <span class="p-name">{{ yellowName }}</span>
          <span class="p-score display">{{ yellowScore }}</span>
          <span class="p-add" :class="{ show: canScore }">＋ point</span>
        </button>
      </div>

      <p v-if="decided" class="won" :class="matchWinnerId === blueId ? 'won-blue' : 'won-yellow'">🏆 {{ winnerName }} wins the match.</p>

      <!-- timeline -->
      <div class="timeline-wrap">
        <h3 class="dash-h">
          Game {{ currentGame?.game_number }} timeline
          <span v-if="canEdit && points.length" class="muted xs">— tap a point to switch who scored</span>
        </h3>
        <div v-if="points.length" class="timeline">
          <div v-for="(grp, gi) in pointGroups" :key="gi" class="grp">
            <button
              v-for="p in grp" :key="p.id"
              class="pt" :class="{ blue: scoredByBlue(p), yellow: !scoredByBlue(p), editable: canEdit }"
              :disabled="!canEdit || busy"
              :title="`Point ${p.point_number}: ${scoredByBlue(p) ? blueName : yellowName} scored`"
              @click="canEdit && lm.flipPoint(p.id)"
            >
              <span class="pt-top" /><span class="pt-bot" />
            </button>
          </div>
        </div>
        <p v-else class="muted">No points yet{{ canScore ? ' — tap a player above to score.' : '.' }}</p>
      </div>

      <!-- controls -->
      <div v-if="isOfficial" class="controls">
        <button v-if="!currentGameDone" class="btn" :disabled="busy" @click="lm.undo()">↶ Undo last point</button>
        <button v-if="canFlipServer" class="btn" :disabled="busy" title="Wrong server? Swap who serves first — first 5 serves only" @click="lm.flipServer()">⇄ Swap server</button>
        <template v-if="canStartNextGame">
          <span class="muted">Next game — who serves?</span>
          <button class="btn btn-blue" :disabled="busy" @click="lm.startNextGame(blueId)">{{ blueName }}</button>
          <button class="btn btn-yellow" :disabled="busy" @click="lm.startNextGame(yellowId)">{{ yellowName }}</button>
        </template>
        <button v-if="decided" class="btn btn-yellow" :disabled="busy" @click="doFinish">{{ isTournament ? 'Finish match ▸' : 'Finish match &amp; apply ratings' }}</button>
        <template v-if="isOfficial">
          <button v-if="!showCancel" class="btn danger" :disabled="busy" @click="showCancel = true">Cancel match</button>
          <span v-else class="confirm">
            <input v-model="cancelReason" class="reason" placeholder="Reason (required)" />
            <button class="btn" :disabled="busy" @click="showCancel = false">Back</button>
            <button class="btn danger" :disabled="busy || !cancelReason.trim()" @click="doCancel">Confirm cancel</button>
          </span>
        </template>
      </div>
    </template>
  </section>
</template>

<style scoped>
.page-title { font-size: 2rem; margin: 0 0 1rem; }
.muted { color: var(--muted); }
.muted.big { font-size: 1.1rem; }
.err { color: var(--bad); }
.xs { font-size: .75rem; }

.empty { padding: 2rem; text-align: center; display: flex; flex-direction: column; align-items: center; gap: 1rem; }

.meta { display: flex; align-items: center; gap: .8rem; margin-bottom: 1rem; }
.games { margin-left: auto; }
.view { color: var(--faint); }

/* tap-to-score panels */
.panels { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; }
.panel {
  position: relative;
  display: flex; flex-direction: column; align-items: center; gap: .5rem;
  padding: 2rem 1rem 1.5rem; border-radius: var(--radius); border: 2px solid var(--line);
  background: var(--surface); color: var(--ink); cursor: default;
  transition: transform .06s ease, filter .15s ease, background .15s ease;
}
.panel.blue { border-color: var(--blue); }
.panel.yellow { border-color: var(--yellow); }
.panel.tappable { cursor: pointer; }
.panel.tappable:hover { filter: brightness(1.08); }
.panel.tappable:active { transform: translateY(2px); }
.panel.serving { box-shadow: 0 0 0 2px var(--ink) inset, var(--shadow); }
.p-serve { font-size: .72rem; text-transform: uppercase; letter-spacing: .06em; color: transparent; }
.p-serve.on { color: var(--good); }
.p-name {
  font-weight: 800; font-size: 1rem; letter-spacing: .02em; text-transform: uppercase;
  padding: .35rem .8rem; border-radius: 7px;
}
.panel.blue .p-name { background: var(--blue); color: #fff; }
.panel.yellow .p-name { background: var(--yellow); color: #1a1300; }
.p-score { font-size: 5rem; line-height: 1; }
.panel.blue .p-score { color: #9cc0ff; }
.panel.yellow .p-score { color: #ffe08a; }
.p-add { font-size: .8rem; color: var(--faint); visibility: hidden; }
.p-add.show { visibility: visible; }

.won { text-align: center; font-weight: 700; font-size: 1.15rem; margin: 1.25rem 0; }
.won-blue { color: #9cc0ff; }
.won-yellow { color: #ffe08a; }

/* timeline */
.timeline-wrap { margin-top: 1.5rem; }
.dash-h { font-size: .95rem; color: var(--muted); margin: 0 0 .6rem; font-weight: 600; }
.timeline { display: flex; flex-wrap: wrap; gap: 10px; align-items: flex-start; }
.grp { display: flex; gap: 5px; padding-right: 10px; border-right: 1px solid var(--line); }
.grp:last-child { padding-right: 0; border-right: 0; }
.pt {
  width: 16px; height: 42px; padding: 0; display: flex; flex-direction: column;
  border: 1px solid var(--line); border-radius: 4px; overflow: hidden; cursor: default; background: none;
}
.pt-top, .pt-bot { flex: 1; }
.pt-top { background: rgba(47, 111, 237, .22); }
.pt-bot { background: rgba(255, 203, 45, .18); }
.pt.blue .pt-top { background: var(--blue); }
.pt.yellow .pt-bot { background: var(--yellow); }
.pt.editable { cursor: pointer; }
.pt.editable:hover { outline: 2px solid var(--ink); outline-offset: 1px; }

/* controls */
.controls { display: flex; flex-wrap: wrap; align-items: center; gap: .6rem; margin-top: 1.75rem; }
.confirm { display: inline-flex; flex-wrap: wrap; align-items: center; gap: .5rem; }
.reason {
  background: var(--bg); border: 1px solid var(--line); color: var(--ink);
  padding: .5rem .7rem; border-radius: var(--radius-sm); font-family: var(--font-ui); min-width: 180px;
}
.btn.danger { background: rgba(244, 81, 108, .16); border-color: var(--bad); color: #ffb3c0; }

@media (max-width: 560px) { .p-score { font-size: 3.5rem; } }
</style>

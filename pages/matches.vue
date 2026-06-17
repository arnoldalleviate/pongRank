<script setup lang="ts">
// Matches hub. Live scoring lives in the top-bar dock (visible on every page),
// so this page is: start-a-match setup (commissioner, when idle), quick
// final-score upload, and the match-history explorer. When a match is live it
// just points you to the dock.
import { ref, computed, watch, onMounted, onUnmounted } from 'vue'

const { isOfficial, isCommissioner } = useRole()
const lm = useLiveMatch()
const { match, names, activePlayers, loading, err, busy } = lm

const mh = useMatchHistory()
const { matches: histMatches, loading: histLoading, err: histErr, busy: histBusy } = mh

function fmtDate(s: string) {
  if (!s) return ''
  return new Date(s).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
}

onMounted(async () => {
  await lm.load()                       // layout owns the live subscription
  if (isOfficial.value) lm.loadActivePlayers()
  mh.load()
  mh.subscribe()
})
onUnmounted(() => { mh.unsubscribe() })

// ---- start-a-match setup (commissioner) ----
const selA = ref('')
const selB = ref('')
const selType = ref<'quick' | 'series'>('quick')
const selFirst = ref('')
const swapColors = ref(false)
const setupValid = computed(() => selA.value && selB.value && selA.value !== selB.value && selFirst.value)

// Blue serves first by default (overridable below)
const bluePlayer = computed(() => (swapColors.value ? selB.value : selA.value))
watch([selA, selB, swapColors], () => { if (bluePlayer.value) selFirst.value = bluePlayer.value })

async function doStart() {
  const ok = await lm.startMatch({
    playerA: selA.value, playerB: selB.value, type: selType.value, firstServer: selFirst.value,
    colorA: swapColors.value ? 'yellow' : 'blue', colorB: swapColors.value ? 'blue' : 'yellow',
  })
  if (ok) navigateTo('/officiate')   // jump straight to scoring
}

// ---- quick final-score upload ----
const selMode = ref<'live' | 'upload'>('live')
const gi = ref([{ a: '', b: '' }, { a: '', b: '' }, { a: '', b: '' }])
const rowsToShow = computed(() => (selType.value === 'series' ? 3 : 1))
function legalGame(a: number, b: number) {
  const hi = Math.max(a, b), lo = Math.min(a, b)
  return Number.isInteger(a) && Number.isInteger(b) && hi >= 11 && hi - lo >= 2
}
const uploadGames = computed(() => {
  const out: { a: number; b: number }[] = []
  for (let i = 0; i < rowsToShow.value; i++) {
    const row = gi.value[i]
    if (row.a === '' && row.b === '') continue
    out.push({ a: parseInt(row.a, 10), b: parseInt(row.b, 10) })
  }
  return out
})
const uploadCheck = computed<{ ok: boolean; msg: string }>(() => {
  if (!selA.value || !selB.value || selA.value === selB.value) return { ok: false, msg: 'Pick two different players' }
  const gs = uploadGames.value
  if (!gs.length) return { ok: false, msg: 'Enter at least one game score' }
  for (const g of gs) if (!legalGame(g.a, g.b)) return { ok: false, msg: 'Each game: winner ≥ 11, win by 2' }
  const need = selType.value === 'series' ? 2 : 1
  let aw = 0, bw = 0
  for (const g of gs) {
    if (aw >= need || bw >= need) return { ok: false, msg: 'Extra game after the match was already decided' }
    if (g.a > g.b) aw++; else bw++
  }
  if (aw < need && bw < need) return { ok: false, msg: 'Not enough games to decide the match' }
  return { ok: true, msg: '' }
})
async function doRecord() {
  if (!uploadCheck.value.ok) return
  const ok = await lm.recordQuickResult({
    playerA: selA.value, playerB: selB.value, type: selType.value, games: uploadGames.value,
    colorA: swapColors.value ? 'yellow' : 'blue', colorB: swapColors.value ? 'blue' : 'yellow',
  })
  if (ok) { gi.value = [{ a: '', b: '' }, { a: '', b: '' }, { a: '', b: '' }]; mh.load() }
}

// delete a completed match (commissioner) — confirm inline, then recompute
const delConfirm = ref<string | null>(null)
async function doDelete(id: string) {
  const ok = await mh.deleteMatch(id)
  if (ok) delConfirm.value = null
}
</script>

<template>
  <section>
    <h1 class="display page-title">Matches</h1>
    <p v-if="err" class="err">{{ err }}</p>
    <p v-if="loading" class="muted">Loading…</p>

    <template v-else>
      <!-- live match runs in the top-bar dock -->
      <div v-if="match" class="card live-note">
        ⬆ Match in progress — score it from the bar at the top of the page.
      </div>

      <!-- idle + commissioner: start a match / quick upload -->
      <div v-else-if="isOfficial" class="card setup">
        <h2 class="setup-h">{{ selMode === 'live' ? 'Start a match' : 'Record a result' }}</h2>
        <div class="grid2">
          <label>Player A ({{ swapColors ? 'yellow' : 'blue' }})
            <select v-model="selA">
              <option value="" disabled>Select…</option>
              <option v-for="p in activePlayers" :key="p.id" :value="p.id" :disabled="p.id === selB">{{ p.name }}</option>
            </select>
          </label>
          <label>Player B ({{ swapColors ? 'blue' : 'yellow' }})
            <select v-model="selB">
              <option value="" disabled>Select…</option>
              <option v-for="p in activePlayers" :key="p.id" :value="p.id" :disabled="p.id === selA">{{ p.name }}</option>
            </select>
          </label>
        </div>

        <div class="grid2">
          <label>Format
            <div class="seg">
              <button :class="{ on: selType === 'quick' }" @click="selType = 'quick'">Quick (1 game)</button>
              <button :class="{ on: selType === 'series' }" @click="selType = 'series'">Series (best of 3)</button>
            </div>
          </label>
          <label>Mode
            <div class="seg">
              <button :class="{ on: selMode === 'live' }" @click="selMode = 'live'">Live scoring</button>
              <button :class="{ on: selMode === 'upload' }" @click="selMode = 'upload'">Quick upload</button>
            </div>
          </label>
        </div>

        <label v-if="selMode === 'live'">First server
          <div class="seg">
            <button :class="{ on: selFirst === selA }" :disabled="!selA" @click="selFirst = selA">{{ names[selA] || 'Player A' }}</button>
            <button :class="{ on: selFirst === selB }" :disabled="!selB" @click="selFirst = selB">{{ names[selB] || 'Player B' }}</button>
          </div>
        </label>

        <div v-else class="uploads">
          <div v-for="i in rowsToShow" :key="i" class="uprow">
            <span class="uplabel mono">Game {{ i }}</span>
            <input v-model="gi[i - 1].a" type="number" min="0" class="upscore mono" :placeholder="names[selA] || 'A'" />
            <span class="updash">–</span>
            <input v-model="gi[i - 1].b" type="number" min="0" class="upscore mono" :placeholder="names[selB] || 'B'" />
          </div>
          <p class="hint muted">{{ uploadCheck.ok ? 'Ready to record.' : uploadCheck.msg }}</p>
        </div>

        <label class="check"><input type="checkbox" v-model="swapColors" /> Swap colors (A yellow / B blue)</label>

        <button v-if="selMode === 'live'" class="btn btn-yellow start" :disabled="!setupValid || busy" @click="doStart">Start match</button>
        <button v-else class="btn btn-yellow start" :disabled="!uploadCheck.ok || busy" @click="doRecord">Record result</button>
      </div>

      <p v-else class="muted big">No match in progress.</p>

      <!-- match history -->
      <section class="history">
        <div class="hist-head">
          <h2 class="hist-h display">Recent matches</h2>
          <span v-if="histMatches.length" class="hist-elo-h">ELO Change</span>
        </div>
        <p v-if="histLoading" class="muted">Loading history…</p>
        <p v-else-if="histErr" class="err">{{ histErr }}</p>
        <p v-else-if="!histMatches.length" class="muted">No matches yet.</p>
        <div v-else class="card hist-list">
          <div
            v-for="m in histMatches"
            :key="m.id"
            class="hrow"
            :class="{ flagged: m.scoringAdjusted, cancelled: m.status === 'cancelled' }"
          >
            <span class="hdate mono">{{ fmtDate(m.completed_at) }}</span>
            <span class="hresult">
              <template v-if="m.status === 'cancelled'">
                {{ m.playerAName }}<span class="vs">vs</span>{{ m.playerBName }}
                <span class="tag cancel">cancelled</span>
                <span v-if="m.cancelReason" class="reason">{{ m.cancelReason }}</span>
              </template>
              <template v-else>
                <strong>{{ m.winnerName }}</strong> defeats {{ m.loserName }}
                <span class="hscore mono">{{ m.scoreLine }}</span>
                <span v-if="m.type === 'series' && m.detail.length" class="hgames mono">({{ m.detail.join(', ') }})</span>
                <span v-if="m.entry_mode === 'quick_upload'" class="tag">uploaded</span>
              </template>
            </span>
            <span v-if="m.status === 'cancelled'" class="helo mono dash">—</span>
            <span
              v-else
              class="helo mono"
              :title="`ELO change — ${m.winnerName}: +${m.winnerElo}, ${m.loserName}: ${m.loserElo}`"
            >
              <span class="pos">+{{ m.winnerElo }}</span> / <span class="neg">{{ m.loserElo }}</span>
            </span>
            <span
              v-if="m.scoringAdjusted"
              class="flag"
              title="Scoring system was adjusted by the commissioner before this match"
            >⚡ adjusted</span>
            <span v-else class="flag-spacer" />
            <span v-if="isCommissioner" class="del">
              <template v-if="delConfirm === m.id">
                <button class="mini" :disabled="histBusy" @click="delConfirm = null">cancel</button>
                <button class="mini danger" :disabled="histBusy" @click="doDelete(m.id)">delete</button>
              </template>
              <button v-else class="mini ghost" :disabled="histBusy" title="Delete match" @click="delConfirm = m.id">🗑</button>
            </span>
          </div>
        </div>
      </section>
    </template>
  </section>
</template>

<style scoped>
.page-title { font-size: 2rem; margin: 0 0 1rem; }
.muted { color: var(--muted); }
.muted.big { font-size: 1.1rem; margin-top: 2rem; text-align: center; }
.err { color: var(--bad); }

.live-note {
  padding: 1rem 1.25rem; margin-bottom: 1.25rem; color: var(--ink);
  border-left: 3px solid var(--blue); font-weight: 600;
}

/* setup */
.setup { padding: 1.25rem; max-width: 640px; margin-bottom: 1.25rem; }
.setup-h { margin: 0 0 1rem; font-size: 1.1rem; }
.grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; margin-bottom: 1rem; }
label { display: flex; flex-direction: column; gap: .4rem; font-size: .85rem; color: var(--muted); }
select {
  background: var(--bg); border: 1px solid var(--line); color: var(--ink);
  padding: .55rem .6rem; border-radius: var(--radius-sm); font-family: var(--font-ui);
}
.seg { display: flex; gap: .4rem; }
.seg button {
  flex: 1; background: var(--surface-2); border: 1px solid var(--line); color: var(--ink);
  padding: .55rem .4rem; border-radius: var(--radius-sm); cursor: pointer; font-size: .85rem;
}
.seg button.on { background: var(--blue); border-color: var(--blue-deep); color: #fff; }
.seg button:disabled { opacity: .4; cursor: not-allowed; }
.check { flex-direction: row; align-items: center; gap: .5rem; margin-bottom: 1rem; }
.start { width: 100%; }
.hint { font-size: .85rem; margin: .4rem 0 0; }

.uploads { margin-bottom: 1rem; }
.uprow { display: flex; align-items: center; gap: .6rem; margin-bottom: .6rem; }
.uplabel { width: 4.5rem; color: var(--muted); font-size: .85rem; }
.upscore {
  width: 4.5rem; text-align: center; background: var(--bg); border: 1px solid var(--line);
  color: var(--ink); padding: .5rem; border-radius: var(--radius-sm);
}
.updash { color: var(--faint); }

/* match history */
.history { margin-top: 2rem; }
.hist-head { display: flex; align-items: baseline; justify-content: space-between; margin: 0 0 .75rem; padding-right: 1rem; }
.hist-h { font-size: 1rem; margin: 0; letter-spacing: .05em; color: var(--muted); }
.hist-elo-h { font-size: .75rem; font-weight: 700; text-transform: uppercase; letter-spacing: .05em; color: var(--ink); white-space: nowrap; }
.hist-list { overflow: hidden; }
.hrow {
  display: grid; grid-template-columns: auto 1fr auto auto auto; gap: .75rem; align-items: center;
  padding: .7rem 1rem; border-bottom: 1px solid var(--line);
}
.hrow:last-child { border-bottom: 0; }
.hrow.flagged { background: rgba(255, 203, 45, .06); }
.hdate { color: var(--faint); font-size: .8rem; white-space: nowrap; }
.hresult { font-size: .92rem; }
.hscore { color: var(--ink); margin-left: .4rem; }
.hgames { color: var(--faint); font-size: .8rem; margin-left: .3rem; }
.helo { font-size: .85rem; white-space: nowrap; text-align: right; cursor: help; }
.helo .pos { color: var(--good); }
.helo .neg { color: var(--bad); }
.tag {
  font-size: .66rem; text-transform: uppercase; letter-spacing: .04em; color: var(--muted);
  border: 1px solid var(--line); border-radius: 999px; padding: .05rem .4rem; margin-left: .45rem;
}
.flag { font-size: .72rem; color: var(--yellow-deep); font-weight: 700; white-space: nowrap; }
.flag-spacer { width: 0; }
.hrow.cancelled { opacity: .72; }
.hrow.cancelled .hresult { color: var(--muted); }
.vs { color: var(--faint); margin: 0 .3rem; }
.tag.cancel { color: #ffb3c0; border-color: var(--bad); }
.reason { color: var(--faint); font-style: italic; margin-left: .4rem; }
.helo.dash { color: var(--faint); cursor: default; }
.del { display: flex; gap: .3rem; justify-content: flex-end; }
.mini { background: var(--surface-2); border: 1px solid var(--line); color: var(--ink); border-radius: 6px; padding: .2rem .5rem; cursor: pointer; font-size: .74rem; }
.mini.ghost { background: none; border-color: transparent; opacity: .55; }
.mini.ghost:hover { opacity: 1; border-color: var(--line); }
.mini.danger { background: rgba(244, 81, 108, .16); border-color: var(--bad); color: #ffb3c0; }
@media (max-width: 640px) {
  .grid2 { grid-template-columns: 1fr; }
  /* stack each history row: date + ELO on top, result full-width, flag/delete footer */
  .hrow {
    grid-template-columns: 1fr auto;
    grid-template-areas:
      "date   elo"
      "result result"
      "meta   del";
    gap: .3rem .75rem;
  }
  .hdate   { grid-area: date; }
  .helo    { grid-area: elo; }
  .hresult { grid-area: result; }
  .flag, .flag-spacer { grid-area: meta; align-self: center; }
  .del     { grid-area: del; }
  /* per-game series breakdown drops to its own full-width line so it isn't clipped */
  .hgames  { display: block; margin: .15rem 0 0; }
}
</style>

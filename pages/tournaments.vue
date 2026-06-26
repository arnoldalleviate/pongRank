<script setup lang="ts">
// Tournaments — single-elimination, live.
//  - Commissioner: create -> seed (ELO order default, reorderable) -> start.
//  - Bracket view for everyone; commissioner taps "Play" on a ready matchup
//    to start it live (jumps to Officiate). Winner auto-advances.
//  - Tournament games are ELO-neutral.
import { ref, computed, watch, onMounted, onUnmounted } from 'vue'

const { isOfficial, isCommissioner } = useRole()
const t = useTournaments()
const { current, rounds, champion, names, seedPool, participants, loading, err, busy } = t
const lm = useLiveMatch()

onMounted(() => {
  t.load()
  t.subscribe()
  if (isCommissioner.value) t.loadSeedPool()
})
onUnmounted(() => t.unsubscribe())

// ---------- create ----------
const newName = ref('')
const newType = ref<'quick' | 'series'>('series')
const newSeeding = ref<'elo' | 'manual' | 'random'>('elo')
async function doCreate() {
  if (!newName.value.trim()) return
  const ok = await t.createTournament(newName.value.trim(), newType.value, newSeeding.value)
  if (ok) newName.value = ''
}

// ---------- seeding (setup) ----------
const seedIds = ref<string[]>([])
watch([seedPool, participants, current], () => {
  if (current.value?.status === 'setup' && seedIds.value.length === 0) {
    seedIds.value = participants.value.length
      ? participants.value.map((p: any) => p.player_id)
      : seedPool.value.map((p: any) => p.id)
    if (current.value?.seeding_method === 'random') shuffleSeeds()
  }
}, { immediate: true })

function nameOf(id: string | null) { return id ? (names.value[id] ?? seedPool.value.find((p: any) => p.id === id)?.name ?? '—') : null }
const available = computed(() => seedPool.value.filter((p: any) => !seedIds.value.includes(p.id)))
const seededList = computed(() => seedIds.value.map((id, i) => ({ id, seed: i + 1, name: nameOf(id) })))
function addSeed(id: string) { if (!seedIds.value.includes(id)) seedIds.value = [...seedIds.value, id] }
function removeSeed(id: string) { seedIds.value = seedIds.value.filter((x) => x !== id) }
function move(i: number, d: number) {
  const a = [...seedIds.value]; const j = i + d
  if (j < 0 || j >= a.length) return
  ;[a[i], a[j]] = [a[j], a[i]]
  seedIds.value = a
}
function shuffleSeeds() {
  const a = [...seedIds.value]
  for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [a[i], a[j]] = [a[j], a[i]] }
  seedIds.value = a
}
async function doStart() {
  if (seedIds.value.length < 2 || !current.value) return
  const ok = await t.setSeeds(current.value.id, seedIds.value)
  if (ok) await t.startTournament(current.value.id)
}

// ---------- bracket ----------
function slotName(id: string | null, round: number) {
  if (id) return names.value[id] ?? '—'
  return round === 1 ? 'Bye' : 'TBD'
}
const liveTmId = computed(() => lm.match.value?.tournament_match_id ?? null)
function isLive(m: any) { return liveTmId.value === m.id }
function playable(m: any) {
  return isOfficial.value && current.value?.status === 'active'
    && m.player_a && m.player_b && !m.winner_id && !lm.match.value
}
async function play(m: any) {
  const ok = await lm.startTournamentMatch({ tmatchId: m.id, firstServer: m.player_a, colorA: 'blue', colorB: 'yellow' })
  if (ok) navigateTo('/officiate')
}
</script>

<template>
  <section>
    <h1 class="display page-title">Tournaments</h1>
    <p v-if="err" class="err">{{ err }}</p>
    <p v-if="loading" class="muted">Loading…</p>

    <template v-else>
      <!-- champion -->
      <p v-if="current?.status === 'completed' && champion" class="champ">🏆 {{ champion }} — Champion</p>

      <!-- create (commissioner; when nothing active/in-setup) -->
      <div v-if="isCommissioner && (!current || current.status === 'completed')" class="card create">
        <h2 class="h">New tournament</h2>
        <div class="row">
          <input v-model="newName" class="inp" type="text" placeholder="Tournament name" />
          <div class="seg">
            <button :class="{ on: newType === 'quick' }" @click="newType = 'quick'">Quick</button>
            <button :class="{ on: newType === 'series' }" @click="newType = 'series'">Best of 3</button>
          </div>
          <div class="seg">
            <button :class="{ on: newSeeding === 'elo' }" @click="newSeeding = 'elo'">Seed by ELO</button>
            <button :class="{ on: newSeeding === 'manual' }" @click="newSeeding = 'manual'">Manual</button>
            <button :class="{ on: newSeeding === 'random' }" @click="newSeeding = 'random'">Random</button>
          </div>
          <button class="btn btn-yellow" :disabled="busy || !newName.trim()" @click="doCreate">Create</button>
        </div>
      </div>

      <!-- setup: seeding -->
      <div v-if="current && current.status === 'setup'" class="card setup">
        <h2 class="h">{{ current.name }} — seed the field</h2>
        <template v-if="isCommissioner">
          <div class="seed-cols">
            <div class="seed-col">
              <div class="col-h">Seeds (in order)</div>
              <div v-for="(s, i) in seededList" :key="s.id" class="seed-row">
                <span class="mono sn">{{ s.seed }}</span>
                <span class="nm">{{ s.name }}</span>
                <span class="acts">
                  <button class="mini" :disabled="i === 0" @click="move(i, -1)">↑</button>
                  <button class="mini" :disabled="i === seededList.length - 1" @click="move(i, 1)">↓</button>
                  <button class="mini" @click="removeSeed(s.id)">✕</button>
                </span>
              </div>
              <p v-if="!seededList.length" class="muted small">No players seeded.</p>
            </div>
            <div class="seed-col">
              <div class="col-h">Available</div>
              <div v-for="p in available" :key="p.id" class="seed-row">
                <span class="nm">{{ p.name }}</span>
                <span class="mono muted small">{{ p.elo }}</span>
                <button class="mini" @click="addSeed(p.id)">＋</button>
              </div>
              <p v-if="!available.length" class="muted small">All players seeded.</p>
            </div>
          </div>
          <div class="seed-actions">
            <button class="btn" :disabled="busy || seedIds.length < 2" @click="shuffleSeeds">🎲 Shuffle</button>
            <button class="btn btn-yellow" :disabled="busy || seedIds.length < 2" @click="doStart">
              Start tournament ({{ seedIds.length }} players)
            </button>
          </div>
        </template>
        <p v-else class="muted">Being set up by the commissioner…</p>
      </div>

      <!-- bracket (active / completed) -->
      <div v-if="current && (current.status === 'active' || current.status === 'completed')" class="bracket-wrap">
        <h2 class="h">{{ current.name }} <span class="muted small">· {{ current.match_type === 'series' ? 'Best of 3' : 'Quick' }}</span></h2>
        <div class="bracket">
          <div v-for="col in rounds" :key="col.round" class="round">
            <div class="round-h">{{ col.round === rounds.length ? 'Final' : 'Round ' + col.round }}</div>
            <div v-for="m in col.matches" :key="m.id" class="bm" :class="{ live: isLive(m), done: !!m.winner_id, third: m.group_id === -1 }">
              <div v-if="m.group_id === -1" class="bm-tag">3rd place</div>
              <div class="slot" :class="{ win: m.winner_id && m.winner_id === m.player_a }">{{ slotName(m.player_a, col.round) }}</div>
              <div class="slot" :class="{ win: m.winner_id && m.winner_id === m.player_b }">{{ slotName(m.player_b, col.round) }}</div>
              <div class="bm-foot">
                <button v-if="playable(m)" class="btn btn-yellow mini" :disabled="busy" @click="play(m)">Play ▸</button>
                <span v-else-if="isLive(m)" class="live-badge">● live</span>
              </div>
            </div>
          </div>
        </div>
      </div>

      <p v-else-if="!current" class="muted big">No tournament in this season yet.</p>
    </template>
  </section>
</template>

<style scoped>
.page-title { font-size: 2rem; margin: 0 0 1rem; }
.muted { color: var(--muted); }
.muted.big { font-size: 1.1rem; text-align: center; margin-top: 2rem; }
.small { font-size: .8rem; }
.err { color: var(--bad); }
.h { font-size: 1.05rem; margin: 0 0 1rem; }
.champ { text-align: center; color: var(--yellow); font-weight: 800; font-size: 1.3rem; margin: 0 0 1.25rem; }

.create { padding: 1.1rem 1.25rem; margin-bottom: 1.25rem; }
.create .row { display: flex; flex-wrap: wrap; gap: .6rem; align-items: center; }
.inp { flex: 1; min-width: 180px; background: var(--bg); border: 1px solid var(--line); color: var(--ink); padding: .55rem .75rem; border-radius: var(--radius-sm); }
.seg { display: flex; gap: .35rem; }
.seg button { background: var(--surface-2); border: 1px solid var(--line); color: var(--ink); padding: .5rem .7rem; border-radius: var(--radius-sm); cursor: pointer; font-size: .82rem; }
.seg button.on { background: var(--blue); border-color: var(--blue-deep); color: #fff; }

.setup { padding: 1.1rem 1.25rem; margin-bottom: 1.25rem; }
.seed-cols { display: grid; grid-template-columns: 1fr 1fr; gap: 1.25rem; }
.col-h { font-size: .78rem; text-transform: uppercase; letter-spacing: .05em; color: var(--faint); margin-bottom: .5rem; }
.seed-row { display: flex; align-items: center; gap: .5rem; padding: .35rem .5rem; border-bottom: 1px solid var(--line); }
.seed-row .nm { flex: 1; font-weight: 600; }
.sn { color: var(--muted); width: 1.5rem; }
.acts { display: flex; gap: .25rem; }
.mini { background: var(--surface-2); border: 1px solid var(--line); color: var(--ink); border-radius: 6px; padding: .2rem .45rem; cursor: pointer; font-size: .78rem; }
.mini:disabled { opacity: .4; cursor: not-allowed; }
.start { margin-top: 1rem; width: 100%; }
.seed-actions { display: flex; gap: .6rem; margin-top: 1rem; }
.seed-actions .btn:last-child { flex: 1; }

.bracket-wrap { overflow-x: auto; }
.bracket { display: flex; gap: 1.5rem; align-items: flex-start; min-width: min-content; }
.round { display: flex; flex-direction: column; gap: 1rem; min-width: 11rem; }
.round-h { font-size: .75rem; text-transform: uppercase; letter-spacing: .06em; color: var(--faint); }
.bm { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius-sm); overflow: hidden; }
.bm.live { border-color: var(--blue); box-shadow: 0 0 0 1px var(--blue); }
.bm.done { opacity: .92; }
.bm.third { border-color: #c2461f; }
.bm-tag { font-size: .6rem; text-transform: uppercase; letter-spacing: .05em; color: #ff8a5c; font-weight: 800; padding: .3rem .6rem .1rem; }
.slot { padding: .5rem .7rem; font-weight: 600; border-bottom: 1px solid var(--line); color: var(--muted); }
.slot.win { color: var(--ink); background: rgba(255, 203, 45, .08); }
.bm-foot { padding: .35rem .5rem; min-height: 1.2rem; display: flex; justify-content: flex-end; }
.live-badge { color: var(--blue); font-size: .72rem; font-weight: 700; }

@media (max-width: 640px) { .seed-cols { grid-template-columns: 1fr; } }
</style>

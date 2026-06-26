<script setup lang="ts">
// Queue = the tournament on-deck list. Shows every bracket matchup that's
// ready to play (both players known, no result yet) and lets an official
// report the final score right here — which advances the bracket (ELO-neutral).
import { ref, reactive, computed, onMounted, onUnmounted } from 'vue'

const { isOfficial } = useRole()
const t = useTournaments()
const { current, rounds, champion, names, loading, err, busy } = t

onMounted(() => { t.load(); t.subscribe() })
onUnmounted(() => t.unsubscribe())

const isSeries = computed(() => current.value?.match_type === 'series')
const totalRounds = computed(() => rounds.value.length)
function roundName(r: number, isThird: boolean) {
  if (isThird) return '3rd place'
  if (r === totalRounds.value) return 'Final'
  if (r === totalRounds.value - 1) return 'Semifinal'
  return 'Round ' + r
}
function nm(id: string | null) { return id ? (names.value[id] ?? '—') : '—' }

// ready matchups (both players, no winner). byes never appear (auto-advanced).
const pending = computed(() => {
  const out: any[] = []
  for (const col of rounds.value) {
    for (const m of col.matches) {
      if (m.player_a && m.player_b && !m.winner_id) {
        out.push({ ...m, label: roundName(col.round, m.group_id === -1) })
      }
    }
  }
  return out
})

// per-match score entry
const scores = reactive<Record<string, { a: string; b: string }[]>>({})
function rowsFor(m: any) {
  if (!scores[m.id]) scores[m.id] = isSeries.value ? [{ a: '', b: '' }, { a: '', b: '' }, { a: '', b: '' }] : [{ a: '', b: '' }]
  return scores[m.id]
}
function legal(a: number, b: number) {
  const hi = Math.max(a, b), lo = Math.min(a, b)
  return Number.isInteger(a) && Number.isInteger(b) && hi >= 11 && hi - lo >= 2
}
function check(m: any) {
  const games = rowsFor(m)
    .filter((r) => r.a !== '' || r.b !== '')
    .map((r) => ({ a: Number(r.a), b: Number(r.b) }))
  if (!games.length) return { ok: false, msg: 'Enter the game scores' }
  let aw = 0, bw = 0
  for (const g of games) {
    if (!legal(g.a, g.b)) return { ok: false, msg: `Illegal game ${g.a}-${g.b} (first to 11, win by 2)` }
    if (g.a > g.b) aw++; else bw++
  }
  const need = isSeries.value ? 2 : 1
  if (aw < need && bw < need) return { ok: false, msg: `Need ${need} game win${need > 1 ? 's' : ''} to decide it` }
  return { ok: true, games }
}
async function submit(m: any) {
  const c = check(m)
  if (!c.ok) return
  const ok = await t.reportMatch(m.id, c.games!)
  if (ok) delete scores[m.id]
}
</script>

<template>
  <section>
    <h1 class="display page-title">Queue</h1>
    <p v-if="err" class="err">{{ err }}</p>
    <p v-if="loading" class="muted">Loading…</p>

    <template v-else>
      <p v-if="!current || current.status === 'completed'" class="muted big">
        No tournament in progress.
        <span v-if="champion">🏆 {{ champion }} took the crown.</span>
      </p>

      <template v-else-if="current.status === 'active'">
        <p class="sub">
          <strong>{{ current.name }}</strong>
          <span class="muted">· {{ isSeries ? 'Best of 3' : 'Single game' }} · report a result to advance the bracket</span>
        </p>

        <p v-if="!pending.length" class="muted big">Nothing ready to play right now — waiting on earlier matches.</p>

        <div v-else class="q-list">
          <div v-for="m in pending" :key="m.id" class="q-card card">
            <div class="q-head">
              <span class="q-round" :class="{ third: m.group_id === -1 }">{{ m.label }}</span>
              <span class="q-vs"><strong>{{ nm(m.player_a) }}</strong> vs <strong>{{ nm(m.player_b) }}</strong></span>
            </div>

            <div v-if="isOfficial" class="q-score">
              <div v-for="(row, i) in rowsFor(m)" :key="i" class="q-game">
                <span class="g-lbl mono">G{{ i + 1 }}</span>
                <input v-model="row.a" type="number" min="0" class="g-in mono" :placeholder="nm(m.player_a)" />
                <span class="g-dash">–</span>
                <input v-model="row.b" type="number" min="0" class="g-in mono" :placeholder="nm(m.player_b)" />
              </div>
              <div class="q-foot">
                <span class="hint muted">{{ check(m).ok ? 'Ready to record.' : check(m).msg }}</span>
                <button class="btn btn-yellow" :disabled="busy || !check(m).ok" @click="submit(m)">Report result</button>
              </div>
            </div>
            <p v-else class="muted small">An official reports the result.</p>
          </div>
        </div>
      </template>
    </template>
  </section>
</template>

<style scoped>
.page-title { font-size: 2rem; margin: 0 0 1rem; }
.muted { color: var(--muted); }
.muted.big { font-size: 1.05rem; margin-top: 1.5rem; }
.small { font-size: .85rem; }
.err { color: var(--bad); }
.sub { margin: 0 0 1.25rem; }
.hint { font-size: .82rem; }

.q-list { display: grid; grid-template-columns: repeat(auto-fill, minmax(20rem, 1fr)); gap: .8rem; }
.q-card { padding: 1rem 1.1rem; }
.q-head { display: flex; flex-direction: column; gap: .35rem; margin-bottom: .8rem; }
.q-round { font-size: .68rem; text-transform: uppercase; letter-spacing: .05em; color: var(--faint); font-weight: 700; }
.q-round.third { color: #ff8a5c; }
.q-vs { font-size: 1rem; }
.q-game { display: flex; align-items: center; gap: .5rem; margin-bottom: .5rem; }
.g-lbl { width: 1.8rem; color: var(--muted); font-size: .82rem; }
.g-in { width: 4.5rem; text-align: center; background: var(--bg); border: 1px solid var(--line); color: var(--ink); padding: .5rem; border-radius: var(--radius-sm); }
.g-dash { color: var(--faint); }
.q-foot { display: flex; align-items: center; justify-content: space-between; gap: .6rem; flex-wrap: wrap; margin-top: .6rem; }

@media (max-width: 640px) { .q-list { grid-template-columns: 1fr; } }
</style>

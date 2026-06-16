<script setup lang="ts">
// Seasons. Everyone sees the active season + archive. Commissioner gets the
// levers: edit config, Start a season (create+activate, confirm), End season
// (archive + retire all players, confirm).
import { ref, reactive, onMounted } from 'vue'

const { isCommissioner } = useRole()
const s = useSeasons()
const { active, archived, activePlayerCount, loading, err, busy } = s

onMounted(() => s.load())

// shared lever form (mode = which action it's driving)
const form = reactive(defaultSeasonForm())
const mode = ref<'start' | 'edit' | null>(null)
function openStart() { Object.assign(form, defaultSeasonForm()); mode.value = 'start' }
function openEdit() { if (active.value) { Object.assign(form, formFromSeason(active.value)); mode.value = 'edit' } }
function closeForm() { mode.value = null; startConfirm.value = false }

// nullable fields come back from number inputs as '' — normalise to null
function normalised() {
  return {
    ...form,
    elo_floor: form.elo_floor === null || (form.elo_floor as any) === '' ? null : Number(form.elo_floor),
    k_override: form.k_override === null || (form.k_override as any) === '' ? null : Number(form.k_override),
  }
}

const startConfirm = ref(false)
const endConfirm = ref(false)
const expandedArchive = ref<string | null>(null)
const archiveRows = ref<any[]>([])

async function submitEdit() {
  if (!active.value) return
  const ok = await s.saveConfig(active.value.id, normalised())
  if (ok) closeForm()
}
async function submitStart() {
  const ok = await s.startSeason(normalised())
  if (ok) closeForm()
}
async function confirmEnd() {
  const ok = await s.endSeason()
  if (ok) endConfirm.value = false
}
async function toggleArchive(id: string) {
  if (expandedArchive.value === id) { expandedArchive.value = null; return }
  archiveRows.value = await s.archiveStandings(id)
  expandedArchive.value = id
}

function fmt(d: string | null) { return d || '—' }
</script>

<template>
  <section>
    <h1 class="display page-title">Seasons</h1>
    <p v-if="err" class="err">{{ err }}</p>
    <p v-if="loading" class="muted">Loading…</p>

    <template v-else>
      <!-- ============ ACTIVE SEASON ============ -->
      <div v-if="active" class="card sea">
        <div class="sea-head">
          <div>
            <span class="pill pill-yellow">active</span>
            <span class="sea-name">{{ active.name }}</span>
          </div>
          <span class="mono muted">config v{{ active.config_version }}</span>
        </div>
        <div class="sea-dates mono">{{ fmt(active.start_date) }} → {{ fmt(active.end_date) }}</div>

        <div class="levers">
          <span>Start {{ active.start_rating }}</span>
          <span>Floor {{ active.elo_floor ?? '—' }}</span>
          <span>K {{ active.k_stable }}/{{ active.k_swingy }} @ {{ active.swingy_after_days }}d</span>
          <span v-if="active.k_override != null">K override {{ active.k_override }}</span>
          <span>MoV {{ active.mov_enabled ? `${active.mov_weight}×, cap ${active.mov_cap}` : 'off' }}</span>
          <span>{{ active.mov_formula_stable }} → {{ active.mov_formula_swingy }}</span>
        </div>

        <div v-if="isCommissioner" class="sea-actions">
          <button class="btn" :disabled="busy" @click="mode === 'edit' ? closeForm() : openEdit()">
            {{ mode === 'edit' ? 'Close' : 'Edit levers' }}
          </button>
          <button v-if="!endConfirm" class="btn danger" :disabled="busy" @click="endConfirm = true">End season</button>
          <span v-else class="confirm">
            <span class="muted small">Archive “{{ active.name }}”, freeze ranks &amp; retire all players?</span>
            <button class="btn small" :disabled="busy" @click="endConfirm = false">No</button>
            <button class="btn danger small" :disabled="busy" @click="confirmEnd">Yes, end season</button>
          </span>
        </div>
      </div>

      <div v-else class="card empty">
        <p class="muted big">No active season.</p>
        <button v-if="isCommissioner && mode !== 'start'" class="btn btn-yellow" @click="openStart">Start a season</button>
      </div>

      <!-- ============ START (commissioner, also available when one is active) ============ -->
      <div v-if="isCommissioner && active && mode !== 'start'" class="start-link">
        <button class="btn" :disabled="busy" @click="openStart">Start a new season…</button>
      </div>

      <!-- ============ LEVER FORM (start or edit) ============ -->
      <div v-if="mode" class="card form">
        <h2 class="form-h">{{ mode === 'start' ? 'Start a season' : `Edit ${active?.name}` }}</h2>
        <div class="grid">
          <label>Name<input v-model="form.name" type="text" /></label>
          <label>Start date<input v-model="form.start_date" type="date" /></label>
          <label>End date<input v-model="form.end_date" type="date" /></label>
          <label>Start rating<input v-model.number="form.start_rating" type="number" /></label>
          <label>ELO floor<input v-model="form.elo_floor" type="number" placeholder="none" /></label>
          <label>K stable (wk 1)<input v-model.number="form.k_stable" type="number" /></label>
          <label>K swingy (wk 2+)<input v-model.number="form.k_swingy" type="number" /></label>
          <label>Swingy after (days)<input v-model.number="form.swingy_after_days" type="number" /></label>
          <label>K override<input v-model="form.k_override" type="number" placeholder="none" /></label>
          <label>MoV weight<input v-model.number="form.mov_weight" type="number" step="0.05" /></label>
          <label>MoV cap<input v-model.number="form.mov_cap" type="number" step="0.05" /></label>
          <label class="check"><input v-model="form.mov_enabled" type="checkbox" /> MoV enabled</label>
          <label>MoV formula — stable
            <select v-model="form.mov_formula_stable"><option value="ratio">ratio</option><option value="log">log</option></select>
          </label>
          <label>MoV formula — swingy
            <select v-model="form.mov_formula_swingy"><option value="ratio">ratio</option><option value="log">log</option></select>
          </label>
        </div>

        <div class="form-actions">
          <button class="btn" :disabled="busy" @click="closeForm">Cancel</button>

          <template v-if="mode === 'edit'">
            <button class="btn btn-yellow" :disabled="busy || !form.name" @click="submitEdit">Save levers</button>
          </template>
          <template v-else>
            <button v-if="!startConfirm" class="btn btn-yellow" :disabled="busy || !form.name" @click="startConfirm = true">Start season…</button>
            <span v-else class="confirm">
              <span class="muted small">Activate “{{ form.name }}” and reset {{ activePlayerCount }} active player(s) to {{ form.start_rating }}? (Archives any current season.)</span>
              <button class="btn small" :disabled="busy" @click="startConfirm = false">No</button>
              <button class="btn btn-yellow small" :disabled="busy" @click="submitStart">Yes, start</button>
            </span>
          </template>
        </div>
        <p v-if="mode === 'start' && activePlayerCount === 0" class="hint muted">
          No active players — reactivate or add players on the Players page first, or this season will start empty.
        </p>
      </div>

      <!-- ============ ARCHIVE (everyone) ============ -->
      <section class="archive">
        <h2 class="form-h">Past seasons</h2>
        <p v-if="!archived.length" class="muted">No archived seasons yet.</p>
        <div v-else class="card arc-list">
          <div v-for="a in archived" :key="a.id" class="arc">
            <button class="arc-row" @click="toggleArchive(a.id)">
              <span class="sea-name">{{ a.name }}</span>
              <span class="mono muted">{{ fmt(a.start_date) }} → {{ fmt(a.end_date) }}</span>
              <span class="muted small">{{ expandedArchive === a.id ? '▲' : '▼' }}</span>
            </button>
            <div v-if="expandedArchive === a.id" class="arc-standings">
              <div v-for="r in archiveRows" :key="r.name" class="arc-srow">
                <span class="mono rank">{{ r.final_rank ?? '—' }}</span>
                <span class="name">{{ r.name }}</span>
                <span class="mono elo">{{ r.elo }}</span>
                <span class="mono muted">{{ r.wins }}–{{ r.losses }}</span>
              </div>
              <p v-if="!archiveRows.length" class="muted small pad">No standings recorded.</p>
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
.muted.big { font-size: 1.1rem; }
.err { color: var(--bad); }
.small { font-size: .8rem; padding: .35rem .6rem; }
.hint { font-size: .82rem; margin: .6rem 0 0; }

.sea { padding: 1.1rem 1.25rem; margin-bottom: 1rem; }
.sea-head { display: flex; align-items: center; justify-content: space-between; gap: 1rem; }
.sea-name { font-weight: 700; font-size: 1.15rem; margin-left: .6rem; }
.sea-dates { color: var(--muted); font-size: .85rem; margin-top: .35rem; }
.levers { display: flex; flex-wrap: wrap; gap: .5rem 1rem; margin-top: .9rem; font-size: .82rem; color: var(--muted); }
.levers span { background: var(--surface-2); border: 1px solid var(--line); border-radius: var(--radius-sm); padding: .25rem .55rem; }
.sea-actions { display: flex; flex-wrap: wrap; align-items: center; gap: .6rem; margin-top: 1rem; }
.confirm { display: inline-flex; flex-wrap: wrap; align-items: center; gap: .5rem; }

.empty { padding: 1.5rem; text-align: center; display: flex; flex-direction: column; gap: 1rem; align-items: center; }
.start-link { margin-bottom: 1rem; }

.form { padding: 1.1rem 1.25rem; margin-bottom: 1.25rem; }
.form-h { font-size: 1rem; margin: 0 0 1rem; }
.grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: .8rem; }
.grid label { display: flex; flex-direction: column; gap: .35rem; font-size: .8rem; color: var(--muted); }
.grid input, .grid select {
  background: var(--bg); border: 1px solid var(--line); color: var(--ink);
  padding: .5rem .6rem; border-radius: var(--radius-sm); font-family: var(--font-ui);
}
.grid .check { flex-direction: row; align-items: center; gap: .5rem; }
.form-actions { display: flex; flex-wrap: wrap; align-items: center; gap: .6rem; margin-top: 1.1rem; }

.archive { margin-top: 1.5rem; }
.arc-list { overflow: hidden; }
.arc { border-bottom: 1px solid var(--line); }
.arc:last-child { border-bottom: 0; }
.arc-row {
  width: 100%; display: grid; grid-template-columns: 1fr auto auto; gap: .75rem; align-items: center;
  background: none; border: 0; color: var(--ink); cursor: pointer; padding: .8rem 1rem; text-align: left;
}
.arc-row:hover { background: var(--surface-2); }
.arc-standings { padding: .25rem 1rem .8rem; }
.arc-srow { display: grid; grid-template-columns: 3rem 1fr 5rem 5rem; gap: .5rem; padding: .35rem 0; border-top: 1px solid var(--line); align-items: center; }
.rank { color: var(--muted); }
.name { font-weight: 600; }
.elo { color: var(--yellow); }
.pad { padding: .5rem 0; }
.btn.danger { background: rgba(244,81,108,.16); border-color: var(--bad); color: #ffb3c0; }

@media (max-width: 640px) { .grid { grid-template-columns: 1fr 1fr; } }
</style>

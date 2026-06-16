<script setup lang="ts">
// Players roster. Everyone sees the list; only the COMMISSIONER can add a
// player or retire/reactivate one (writes go through the code-gated rpcs —
// the UI gating here is cosmetic, the DB re-checks the commissioner code).
const supabase = useSupabase()
const { isCommissioner, accessCode } = useRole()

const players = ref<any[]>([])
const loading = ref(true)
const err = ref<string | null>(null)

const newName = ref('')
const busy = ref(false)
const confirmId = ref<string | null>(null)   // player pending retire confirmation

async function load() {
  loading.value = true
  const { data, error } = await supabase
    .from('players')
    .select('id,name,is_active')
    .order('name')
  if (error) err.value = error.message
  else players.value = data ?? []
  loading.value = false
}
onMounted(load)

const active = computed(() => players.value.filter(p => p.is_active))
const retired = computed(() => players.value.filter(p => !p.is_active))

async function addPlayer() {
  const name = newName.value.trim()
  if (!name || busy.value) return
  busy.value = true; err.value = null
  const { error } = await supabase.rpc('add_player', { p_code: accessCode.value, p_name: name })
  if (error) err.value = error.message
  else { newName.value = ''; await load() }
  busy.value = false
}

async function setActive(id: string, makeActive: boolean) {
  if (busy.value) return
  busy.value = true; err.value = null
  const { error } = await supabase.rpc('set_player_active', {
    p_code: accessCode.value, p_player_id: id, p_active: makeActive,
  })
  if (error) err.value = error.message
  else { confirmId.value = null; await load() }
  busy.value = false
}
</script>

<template>
  <section>
    <h1 class="display page-title">Players</h1>

    <!-- commissioner-only: add a player -->
    <div v-if="isCommissioner" class="card add">
      <input
        v-model="newName"
        class="add-input"
        type="text"
        placeholder="New player name"
        :disabled="busy"
        @keyup.enter="addPlayer"
      />
      <button class="btn btn-yellow" :disabled="busy || !newName.trim()" @click="addPlayer">Add player</button>
    </div>

    <p v-if="err" class="err">{{ err }}</p>
    <p v-if="loading" class="muted">Loading roster…</p>

    <template v-else>
      <!-- active roster -->
      <div class="card table" v-if="active.length">
        <div class="row head"><span>Active players</span><span /></div>
        <div v-for="p in active" :key="p.id" class="row">
          <span class="name">{{ p.name }}</span>
          <span class="actions">
            <template v-if="isCommissioner">
              <template v-if="confirmId === p.id">
                <span class="muted small">Retire {{ p.name }}?</span>
                <button class="btn small" :disabled="busy" @click="confirmId = null">No</button>
                <button class="btn btn-blue small" :disabled="busy" @click="setActive(p.id, false)">Yes, retire</button>
              </template>
              <button v-else class="btn small" :disabled="busy" @click="confirmId = p.id">Retire</button>
            </template>
          </span>
        </div>
      </div>
      <p v-else class="muted">No active players yet.</p>

      <!-- retired roster -->
      <div class="card table retired-card" v-if="retired.length">
        <div class="row head"><span>Retired</span><span /></div>
        <div v-for="p in retired" :key="p.id" class="row">
          <span class="name dim">{{ p.name }}</span>
          <span class="actions">
            <button v-if="isCommissioner" class="btn small" :disabled="busy" @click="setActive(p.id, true)">Reactivate</button>
          </span>
        </div>
      </div>
    </template>
  </section>
</template>

<style scoped>
.page-title { font-size: 2rem; margin: 0 0 1rem; }
.muted { color: var(--muted); }
.small { font-size: .8rem; padding: .35rem .6rem; }
.err { color: var(--bad); margin: .5rem 0; }

.add { display: flex; gap: .5rem; padding: .75rem; margin-bottom: 1rem; }
.add-input {
  flex: 1; background: var(--bg); border: 1px solid var(--line); color: var(--ink);
  padding: .55rem .75rem; border-radius: var(--radius-sm); font-family: var(--font-ui);
}

.table { overflow: hidden; margin-bottom: 1.25rem; }
.row {
  display: grid; grid-template-columns: 1fr auto; align-items: center; gap: .5rem;
  padding: .7rem 1rem; border-bottom: 1px solid var(--line);
}
.row:last-child { border-bottom: 0; }
.head { color: var(--faint); font-size: .78rem; text-transform: uppercase; letter-spacing: .05em; }
.name { font-weight: 600; }
.dim { color: var(--muted); }
.actions { display: flex; align-items: center; gap: .5rem; justify-content: flex-end; }
.retired-card { opacity: .85; }
</style>

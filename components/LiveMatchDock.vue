<script setup lang="ts">
// Read-only broadcast scorebug baked into the top bar (a full-width row inside
// the header). DISPLAY ONLY — officiating lives on the /officiate dashboard.
// Format:  [BLUE NAME] score : score [YELLOW NAME]
import { computed } from 'vue'

const lm = useLiveMatch()
const { match, names, currentGame, serverId, aGamesWon, bGamesWon, decided, matchWinnerId } = lm

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
const winnerIsBlue = computed(() => matchWinnerId.value === blueId.value)

// match lifecycle status shown in the bar
const status = computed(() => {
  if (!match.value) return 'ready'
  if (decided.value) return 'ending'
  const g = currentGame.value
  if (!g || (g.score_a === 0 && g.score_b === 0)) return 'starting'
  return 'live'
})
</script>

<template>
  <div class="dock-bar">
    <div class="status">
      <span class="tag" :class="`tag-${status}`"><span class="tag-dot" />{{ status.toUpperCase() }}</span>
      <span class="meta mono">{{ match?.type === 'series' ? 'BO3' : 'QUICK' }} · G{{ currentGame?.game_number }}<template v-if="match?.type === 'series'"> · {{ blueGames }}–{{ yellowGames }}</template></span>
    </div>

    <!-- [BLUE NAME] score : score [YELLOW NAME] -->
    <div class="scorebug">
      <div class="half blue" :class="{ serving: servingBlue }">
        <Confetti v-if="decided && winnerIsBlue" mode="burst" />
        <span class="serve" :class="{ on: servingBlue }" :title="servingBlue ? 'serving' : undefined">🏓</span>
        <span class="badge">{{ blueName }}</span>
        <span class="num">{{ blueScore }}</span>
      </div>
      <span class="sep">:</span>
      <div class="half yellow" :class="{ serving: servingYellow }">
        <Confetti v-if="decided && !winnerIsBlue" mode="burst" />
        <span class="num">{{ yellowScore }}</span>
        <span class="badge">{{ yellowName }}</span>
        <span class="serve" :class="{ on: servingYellow }" :title="servingYellow ? 'serving' : undefined">🏓</span>
      </div>
    </div>

    <span v-if="decided" class="won" :class="winnerIsBlue ? 'won-blue' : 'won-yellow'">🏆 {{ winnerName }} wins</span>
  </div>
</template>

<style scoped>
/* full-width row inside the header (no own background — it's part of the bar) */
.dock-bar {
  flex: 0 0 100%; width: 100%;
  display: flex; align-items: center; justify-content: center; gap: 1.75rem; flex-wrap: wrap;
  margin-top: .7rem; padding-top: .8rem; border-top: 1px solid var(--line);
}

.status { display: flex; flex-direction: column; gap: .25rem; }
.tag { display: inline-flex; align-items: center; gap: .4rem; font-size: .72rem; font-weight: 800; letter-spacing: .12em; }
.tag-dot { width: 8px; height: 8px; border-radius: 50%; }
.tag-starting { color: #9cc0ff; }
.tag-starting .tag-dot { background: var(--blue); }
.tag-live { color: var(--bad); }
.tag-live .tag-dot { background: var(--bad); animation: live-blink 1.4s ease-in-out infinite; }
.tag-ending { color: var(--yellow); }
.tag-ending .tag-dot { background: var(--yellow); animation: live-blink 1.4s ease-in-out infinite; }
@keyframes live-blink { 0%, 100% { opacity: 1; } 50% { opacity: .25; } }
.meta { font-size: .72rem; color: var(--faint); letter-spacing: .06em; }

.scorebug {
  display: inline-flex; align-items: stretch;
  background: var(--surface-2); border: 1px solid var(--line); border-radius: 12px;
  overflow: hidden; box-shadow: var(--shadow);
  cursor: default; user-select: none;
}
.half { position: relative; display: inline-flex; align-items: center; gap: .9rem; padding: .55rem 1.1rem; }
.half.serving { background: rgba(255, 255, 255, .04); }
.badge {
  font-family: var(--font-ui); font-weight: 800; font-size: .9rem; letter-spacing: .03em;
  text-transform: uppercase; padding: .4rem .8rem; border-radius: 7px; white-space: nowrap;
}
.half.blue .badge { background: var(--blue); color: #fff; }
.half.yellow .badge { background: var(--yellow); color: #1a1300; }
.num { font-family: var(--font-display); font-size: 2.4rem; line-height: 1; min-width: 1.6ch; text-align: center; }
.half.blue .num { color: #cfe0ff; }
.half.yellow .num { color: #ffe9ad; }
.sep { display: flex; align-items: center; font-family: var(--font-display); font-size: 1.5rem; color: var(--muted); padding: 0 .35rem; }
.serve { font-size: .85rem; filter: grayscale(1) opacity(.25); }
.serve.on { filter: none; }
.won { font-weight: 700; font-size: .9rem; }
.won-blue { color: #9cc0ff; }
.won-yellow { color: #ffe08a; }

@media (max-width: 560px) {
  .num { font-size: 2rem; }
  .badge { font-size: .8rem; padding: .35rem .6rem; }
  .dock-bar { gap: 1rem; }
}
</style>

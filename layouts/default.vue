<script setup lang="ts">
const { role, isOfficial, isCommissioner, init, setCode, clear } = useRole()
const { match: liveMatch, decided, start: startLiveMatch } = useLiveMatch()
const showCodeEntry = ref(false)
const codeInput = ref('')
const menuOpen = ref(false)   // mobile hamburger drawer

onMounted(() => {
  init()
  startLiveMatch()
})

async function submitCode() {
  await setCode(codeInput.value)
  codeInput.value = ''
  showCodeEntry.value = false
}
</script>

<template>
  <div class="shell">
    <header class="topbar">
      <NuxtLink to="/" class="brand">
        <span class="dot dot-blue" /><span class="dot dot-yellow" />
        <span class="display brand-name">Ping&nbsp;League</span>
      </NuxtLink>

      <NuxtLink v-if="!liveMatch && isOfficial" to="/matches" class="create-cta">
        <span class="cta-plus" aria-hidden="true">＋</span> Create match
      </NuxtLink>

      <button
        class="hamburger"
        :class="{ open: menuOpen }"
        :aria-expanded="menuOpen"
        aria-label="Toggle navigation menu"
        @click="menuOpen = !menuOpen"
      >
        <span /><span /><span />
      </button>

      <nav class="nav" :class="{ open: menuOpen }" @click="menuOpen = false">
        <NuxtLink to="/" class="navlink">Leaderboard</NuxtLink>
        <NuxtLink to="/players" class="navlink">Players</NuxtLink>
        <NuxtLink to="/matches" class="navlink">Matches</NuxtLink>
        <NuxtLink to="/officiate" class="navlink">Officiate</NuxtLink>
        <NuxtLink to="/queue" class="navlink">Queue</NuxtLink>
        <NuxtLink to="/tournaments" class="navlink">Tournaments</NuxtLink>
        <NuxtLink to="/seasons" class="navlink">Seasons</NuxtLink>
      </nav>

      <div class="role-area" :class="{ show: menuOpen }">
        <span
          class="pill"
          :class="{ 'pill-blue': isOfficial && !isCommissioner, 'pill-yellow': isCommissioner }"
        >{{ role }}</span>
        <button v-if="role === 'viewer'" class="btn" @click="showCodeEntry = !showCodeEntry">Enter code</button>
        <button v-else class="btn" @click="clear">Sign out</button>
      </div>

      <LiveMatchDock v-if="liveMatch" />
      <Confetti v-if="liveMatch && decided" mode="rain" />
    </header>

    <div v-if="showCodeEntry" class="code-entry card">
      <input
        v-model="codeInput"
        class="code-input"
        type="password"
        placeholder="official / commissioner code"
        @keyup.enter="submitCode"
      />
      <button class="btn btn-blue" @click="submitCode">Unlock</button>
    </div>

    <main class="content">
      <slot />
    </main>
  </div>
</template>

<style scoped>
.shell { min-height: 100%; display: flex; flex-direction: column; }
.topbar {
  display: flex; align-items: center; gap: 1.5rem;
  padding: .9rem 1.25rem; border-bottom: 1px solid var(--line);
  background: rgba(10,26,51,.7); backdrop-filter: blur(8px);
  position: sticky; top: 0; z-index: 10; flex-wrap: wrap;
}
.brand { display: flex; align-items: center; gap: .5rem; text-decoration: none; }
.brand-name { font-size: 1.15rem; color: var(--ink); }
.dot { width: 12px; height: 12px; border-radius: 50%; display: inline-block; }
.dot-blue { background: var(--blue); }
.dot-yellow { background: var(--yellow); margin-left: -6px; }
.nav { display: flex; gap: 1rem; margin-left: auto; }
.navlink { color: var(--muted); text-decoration: none; font-weight: 600; font-size: .92rem; }
.navlink:hover, .router-link-active { color: var(--ink); }

/* Prominent centered shortcut so the commissioner never hunts for it. */
.create-cta {
  position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%); z-index: 11;
  display: inline-flex; align-items: center; gap: .4rem;
  background: var(--yellow); color: #1a1300;
  border: 1px solid var(--yellow-deep); border-radius: 999px;
  padding: .5rem 1.1rem; text-decoration: none;
  font-weight: 700; font-size: .9rem; letter-spacing: .02em;
  box-shadow: 0 6px 18px -6px rgba(255,203,45,.5);
  white-space: nowrap; transition: filter .15s ease;
}
.create-cta:hover { filter: brightness(1.07); }
.cta-plus { font-size: 1.15em; font-weight: 800; line-height: 1; margin-top: -1px; }

.role-area { display: flex; align-items: center; gap: .6rem; }

/* hamburger — hidden on desktop, shown on mobile via the media query below */
.hamburger {
  display: none; flex-direction: column; justify-content: center; gap: 5px;
  width: 44px; height: 40px; padding: 0 10px; cursor: pointer;
  background: var(--surface-2); border: 1px solid var(--line); border-radius: var(--radius-sm);
}
.hamburger span { display: block; height: 2px; width: 100%; background: var(--ink); border-radius: 2px; transition: transform .2s ease, opacity .2s ease; }
.hamburger.open span:nth-child(1) { transform: translateY(7px) rotate(45deg); }
.hamburger.open span:nth-child(2) { opacity: 0; }
.hamburger.open span:nth-child(3) { transform: translateY(-7px) rotate(-45deg); }

.code-entry { display: flex; gap: .5rem; margin: .75rem 1.25rem 0; padding: .75rem; }
.code-input {
  flex: 1; background: var(--bg); border: 1px solid var(--line); color: var(--ink);
  padding: .55rem .75rem; border-radius: var(--radius-sm); font-family: var(--font-mono);
}
.content { padding: 1.5rem 1.25rem; max-width: 1100px; width: 100%; margin: 0 auto; }

/* Below desktop widths, drop the CTA out of absolute-center onto its own
   full-width row so it never overlaps the nav. */
@media (max-width: 1199px) {
  .create-cta {
    position: static; transform: none; order: 10;
    width: 100%; justify-content: center; margin-top: .15rem;
  }
}

/* Mobile/tablet: the 7-link nav no longer fits, so collapse nav + role
   controls into a hamburger-toggled drawer. Top row becomes brand + burger. */
@media (max-width: 960px) {
  .topbar { gap: .9rem; }
  .hamburger { display: flex; margin-left: auto; }

  .nav, .role-area { display: none; }            /* hidden until the drawer opens */
  .nav.open {
    display: flex; flex-direction: column; flex: 0 0 100%; order: 11;
    margin: .6rem 0 0; padding-top: .3rem; border-top: 1px solid var(--line); gap: 0;
  }
  .nav.open .navlink {
    padding: .8rem .25rem; font-size: 1.02rem; border-bottom: 1px solid var(--line);
  }
  .nav.open .navlink:last-child { border-bottom: 0; }
  .role-area.show {
    display: flex; flex: 0 0 100%; order: 12; margin-top: .7rem; justify-content: flex-start;
  }
}
</style>

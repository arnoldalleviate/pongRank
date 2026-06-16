<script setup lang="ts">
// Lightweight CSS confetti (no deps). mode='rain' falls across the container;
// mode='burst' shoots up/out from the bottom-centre. Particles are generated
// once on the client (Math.random is fine in the browser). Absolutely
// positioned + pointer-events:none so it never blocks clicks.
import { computed } from 'vue'

const props = withDefaults(defineProps<{ mode?: 'rain' | 'burst'; count?: number }>(), {
  mode: 'rain',
  count: 36,
})

const COLORS = ['var(--blue)', 'var(--yellow)', '#ffffff', '#9cc0ff', '#ffe08a']

const bits = computed(() =>
  Array.from({ length: props.count }, (_, i) => ({
    left: Math.round(Math.random() * 100),
    delay: +(Math.random() * 2).toFixed(2),
    dur: +(1.6 + Math.random() * 1.8).toFixed(2),
    color: COLORS[i % COLORS.length],
    size: Math.round(5 + Math.random() * 6),
    rot: Math.round(Math.random() * 360),
    xd: Math.round((Math.random() * 2 - 1) * 70),     // burst x drift
    yd: -Math.round(50 + Math.random() * 90),         // burst rise
  })))
</script>

<template>
  <div class="confetti" :class="mode" aria-hidden="true">
    <span
      v-for="(b, i) in bits" :key="i" class="bit"
      :style="{
        left: b.left + '%',
        width: b.size + 'px',
        height: Math.round(b.size * 0.5) + 'px',
        background: b.color,
        animationDelay: b.delay + 's',
        animationDuration: b.dur + 's',
        '--rot': b.rot + 'deg',
        '--xd': b.xd + 'px',
        '--yd': b.yd + 'px',
      }"
    />
  </div>
</template>

<style scoped>
.confetti { position: absolute; inset: 0; overflow: hidden; pointer-events: none; z-index: 30; }
.confetti.burst { overflow: visible; }
.bit { position: absolute; border-radius: 1px; opacity: 0; will-change: transform, opacity; }

/* rain: fall from the top across the container */
.confetti.rain .bit { top: -10px; animation-name: cf-fall; animation-iteration-count: infinite; animation-timing-function: linear; }
@keyframes cf-fall {
  0%   { transform: translateY(-10px) rotate(0); opacity: 0; }
  10%  { opacity: 1; }
  100% { transform: translateY(160px) rotate(var(--rot)); opacity: 0; }
}

/* burst: shoot up/out from the bottom-centre */
.confetti.burst .bit { bottom: 20%; left: 50%; animation-name: cf-burst; animation-iteration-count: infinite; animation-timing-function: ease-out; }
@keyframes cf-burst {
  0%   { transform: translate(0, 0) rotate(0); opacity: 0; }
  12%  { opacity: 1; }
  100% { transform: translate(var(--xd), var(--yd)) rotate(var(--rot)); opacity: 0; }
}
</style>

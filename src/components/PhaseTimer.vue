<script setup lang="ts">
import { ref, computed, watch, onMounted, onUnmounted } from 'vue'

const props = defineProps<{
  endTime?: string
  phase: string
}>()

const emit = defineEmits<{
  timeout: []
}>()

const now = ref(Date.now())
let interval: number | null = null
const lastFiredEndTime = ref<string | null>(null)
let lastEmitAt = 0
/** Süre doldu ama tur ilerlemediyse (DB hatası vb.) yeniden dene */
const RETRY_INTERVAL_MS = 3000

const tryEmitTimeout = () => {
  if (!props.endTime || remainingSeconds.value > 0) return
  const nowMs = Date.now()
  const endKey = props.endTime
  if (lastFiredEndTime.value === endKey && nowMs - lastEmitAt < RETRY_INTERVAL_MS) return
  lastFiredEndTime.value = endKey
  lastEmitAt = nowMs
  emit('timeout')
}

const remainingSeconds = computed(() => {
  if (!props.endTime) return 0
  const diff = new Date(props.endTime).getTime() - now.value
  return Math.max(0, Math.ceil(diff / 1000))
})

const progress = computed(() => {
  if (!props.endTime) return 0
  const phaseDurations: Record<string, number> = {
    discussion: 60,
    voting: 45,
    authority_selection: 30,
    advisor_selection: 30,
    reveal: 5,
    card_peek: 25,
    role_peek: 25,
    authority_view_role: 15,
    authority_kill: 15,
    player_kill: 20,
  }
  const totalDuration = phaseDurations[props.phase] || 30
  return (remainingSeconds.value / totalDuration) * 100
})

const color = computed(() => {
  if (remainingSeconds.value > 10) return 'success'
  if (remainingSeconds.value > 5) return 'warning'
  return 'error'
})

const phaseText = computed(() => {
  switch (props.phase) {
    case 'discussion': return 'Tartışma'
    case 'voting': return 'Oylama'
    case 'authority_selection': return 'Yetkili Kart Seçiyor'
    case 'advisor_selection': return 'Danışan Kart Seçiyor'
    case 'reveal': return 'Kart Açılıyor'
    case 'card_peek':
    case 'role_peek': return 'Gizli Rol Görüntüleme'
    case 'authority_view_role': return 'Yetkili Rol Görüyor'
    case 'authority_kill': return 'Yetkili Oyun Dışı Ediyor'
    case 'player_kill': return 'Öldürme Gücü'
    default: return ''
  }
})

watch(() => props.endTime, () => {
  lastFiredEndTime.value = null
  lastEmitAt = 0
  now.value = Date.now()
  tryEmitTimeout()
})

watch(remainingSeconds, () => {
  tryEmitTimeout()
})

onMounted(() => {
  tryEmitTimeout()
  interval = window.setInterval(() => {
    now.value = Date.now()
    tryEmitTimeout()
  }, 100)
})

onUnmounted(() => {
  if (interval) clearInterval(interval)
})
</script>

<template>
  <v-card v-if="endTime" color="surface-variant" variant="tonal" class="timer-card">
    <v-card-text class="text-center pa-4">
      <div class="text-h6 mb-2 phase-text">{{ phaseText }}</div>
      <v-progress-circular
        :model-value="progress"
        :size="80"
        :width="8"
        :color="color"
        class="timer-progress"
      >
        <span class="text-h5 timer-value">{{ remainingSeconds }}</span>
      </v-progress-circular>
    </v-card-text>
  </v-card>
</template>

<style scoped>
.timer-card {
  background: linear-gradient(145deg, rgba(21, 27, 61, 0.9) 0%, rgba(26, 35, 81, 0.9) 100%) !important;
  border: 2px solid rgba(255, 107, 53, 0.4);
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4), 0 0 30px rgba(255, 107, 53, 0.3);
  animation: timerPulse 2s ease-in-out infinite;
}

@keyframes timerPulse {
  0%, 100% { box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4), 0 0 30px rgba(255, 107, 53, 0.3); }
  50% { box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4), 0 0 50px rgba(255, 107, 53, 0.6); }
}

.phase-text {
  font-weight: 700;
  text-shadow: 0 2px 8px rgba(0, 0, 0, 0.5);
  color: #FF6B35;
  text-transform: uppercase;
  letter-spacing: 1px;
}

.timer-progress {
  filter: drop-shadow(0 0 20px rgba(255, 107, 53, 0.5));
}

.timer-value {
  font-weight: 800;
  text-shadow: 0 2px 8px rgba(0, 0, 0, 0.8);
}
</style>

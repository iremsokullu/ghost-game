<script setup lang="ts">
import { computed, onMounted, onUnmounted } from 'vue'
import { useRoute } from 'vue-router'
import {
  playButtonClick,
  soundEnabled,
  toggleSound,
  unlockAudio,
} from './lib/audio'

const route = useRoute()
const isGameRoom = computed(() => route.name === 'GameRoom')

const handleAppClick = (event: MouseEvent) => {
  unlockAudio()
  const target = event.target as HTMLElement | null
  const button = target?.closest('button')
  if (!button || button.disabled || button.getAttribute('aria-disabled') === 'true') return
  playButtonClick()
}

onMounted(() => {
  window.addEventListener('pointerdown', unlockAudio, { once: true })
})

onUnmounted(() => {
  window.removeEventListener('pointerdown', unlockAudio)
})
</script>

<template>
  <v-app @click.capture="handleAppClick">
    <v-app-bar prominent class="app-bar-gradient">
      <v-app-bar-title class="text-h5 font-weight-bold app-title">
        GHOST
      </v-app-bar-title>

      <template #append>
        <div class="sound-controls">
          <v-btn
            :icon="soundEnabled ? 'mdi-volume-high' : 'mdi-volume-off'"
            variant="text"
            size="small"
            :aria-label="soundEnabled ? 'Sesleri kapat' : 'Sesleri aç'"
            @click.stop="toggleSound"
          />
        </div>
      </template>
    </v-app-bar>

    <v-main :class="['app-main', isGameRoom ? 'app-main--room' : 'app-main--home']">
      <router-view />
    </v-main>
  </v-app>
</template>

<style>
* {
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}

body {
  font-family: 'Roboto', sans-serif;
  background: #0A0E27;
}

.v-application {
  min-height: 100vh;
}

.app-main {
  min-height: calc(100vh - 64px);
}

.app-main--home {
  overflow: auto;
}

.app-main--room {
  overflow: hidden;
}

.app-main--room > * {
  height: 100%;
  min-height: 0;
}

.app-bar-gradient {
  background: linear-gradient(135deg, #0D47A1 0%, #00838F 50%, #FF6B35 100%) !important;
  box-shadow: 0 4px 20px rgba(0, 0, 0, 0.5), 0 0 30px rgba(255, 107, 53, 0.3) !important;
}

.app-title {
  text-shadow: 0 2px 8px rgba(0, 0, 0, 0.5);
  font-weight: 800 !important;
  letter-spacing: 2px;
}

.sound-controls {
  display: flex;
  align-items: center;
  gap: 4px;
  margin-right: 8px;
}

::-webkit-scrollbar {
  width: 12px;
}

::-webkit-scrollbar-track {
  background: #0A0E27;
}

::-webkit-scrollbar-thumb {
  background: linear-gradient(180deg, #0D47A1 0%, #FF6B35 100%);
  border-radius: 6px;
  border: 2px solid #0A0E27;
}

::-webkit-scrollbar-thumb:hover {
  background: linear-gradient(180deg, #1565C0 0%, #FF8A50 100%);
}
</style>

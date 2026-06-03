<script setup lang="ts">
import { computed } from 'vue'
import type { Player } from '../lib/supabase'

const props = defineProps<{
  players: Player[]
  currentPlayerId: string
  showRoles?: boolean
  revealAllRoles?: boolean
}>()

const currentPlayer = computed(() =>
  props.players.find(p => p.id === props.currentPlayerId)
)

/** Sadık ve Özel Ajan: sadece kendi rolü. Hain: diğer hainleri ve Özel Ajan'ı görür. */
const canSeeRole = (player: Player) => {
  if (props.revealAllRoles) return !!player.role
  if (!props.showRoles) return false
  if (player.id === props.currentPlayerId) return true
  const myRole = currentPlayer.value?.role
  if (myRole === 'hain') {
    return player.role === 'hain' || player.role === 'ajan'
  }
  return false
}

const getRoleIcon = (role?: string) => {
  switch (role) {
    case 'sadik':
      return 'mdi-shield-check'
    case 'hain':
      return 'mdi-skull'
    case 'ajan':
      return 'mdi-incognito'
    default:
      return 'mdi-account'
  }
}

const getRoleText = (role?: string) => {
  switch (role) {
    case 'sadik':
      return 'Sadık'
    case 'hain':
      return 'Hain'
    case 'ajan':
      return 'Özel Ajan'
    default:
      return 'Bilinmiyor'
  }
}

/** Sadıklar yeşil, Hain + Özel Ajan kırmızı */
const avatarClass = (player: Player) => {
  if (!canSeeRole(player) || !player.role) return 'avatar-neutral'
  if (player.role === 'sadik') return 'avatar-sadik'
  return 'avatar-hain'
}

const myRoleAlertClass = computed(() => {
  const r = currentPlayer.value?.role
  if (r === 'sadik') return 'role-alert-sadik'
  if (r === 'hain' || r === 'ajan') return 'role-alert-hain'
  return 'role-alert-neutral'
})
</script>

<template>
  <v-card elevation="4" class="players-card">
    <v-card-title class="bg-secondary text-white">
      <v-icon start>mdi-account-group</v-icon>
      {{ revealAllRoles ? 'Tüm Roller' : 'Oyuncular' }} ({{ players.length }})
    </v-card-title>

    <v-card-text v-if="showRoles && currentPlayer?.role && !revealAllRoles" class="role-card-wrap">
      <v-alert
        :class="myRoleAlertClass"
        variant="tonal"
        prominent
      >
        <div class="d-flex align-center">
          <v-icon :icon="getRoleIcon(currentPlayer.role)" size="large" class="mr-3" />
          <div>
            <div class="text-h6">Senin Rolün:</div>
            <div class="text-h5 font-weight-bold">{{ getRoleText(currentPlayer.role) }}</div>
          </div>
        </div>
      </v-alert>
    </v-card-text>

    <v-list class="players-list-scroll">
      <v-list-item
        v-for="player in players"
        :key="player.id"
        :class="{ 'bg-primary-lighten': player.id === currentPlayerId }"
      >
        <template #prepend>
          <v-avatar :class="avatarClass(player)" size="40">
            <v-icon color="white">{{ getRoleIcon(canSeeRole(player) ? player.role : undefined) }}</v-icon>
          </v-avatar>
        </template>

        <v-list-item-title class="font-weight-bold">
          {{ player.name }}
          <v-chip
            v-if="player.is_host"
            size="x-small"
            color="warning"
            class="ml-2"
          >
            HOST
          </v-chip>
          <v-chip
            v-if="player.id === currentPlayerId"
            size="x-small"
            color="info"
            class="ml-2"
          >
            SEN
          </v-chip>
        </v-list-item-title>

        <v-list-item-subtitle v-if="canSeeRole(player) && player.role">
          {{ getRoleText(player.role) }}
        </v-list-item-subtitle>

        <template #append>
          <v-icon v-if="!player.is_alive" color="error">
            mdi-close-circle
          </v-icon>
        </template>
      </v-list-item>
    </v-list>

  </v-card>
</template>

<style scoped>
.bg-primary-lighten {
  background: linear-gradient(135deg, rgba(13, 71, 161, 0.2) 0%, rgba(0, 131, 143, 0.2) 100%);
  border-left: 4px solid rgba(255, 107, 53, 0.8);
}

.avatar-sadik {
  background: #43a047 !important;
  border: 2px solid #66bb6a;
}

.avatar-hain {
  background: #c62828 !important;
  border: 2px solid #ef5350;
}

.avatar-neutral {
  background: #455a64 !important;
  border: 2px solid rgba(255, 255, 255, 0.2);
}

.role-alert-sadik {
  background: rgba(67, 160, 71, 0.2) !important;
  border: 2px solid #43a047;
  color: #a5d6a7;
}

.role-alert-hain {
  background: rgba(198, 40, 40, 0.2) !important;
  border: 2px solid #c62828;
  color: #ef9a9a;
}

.role-alert-neutral {
  background: rgba(69, 90, 100, 0.3) !important;
}

.role-card-wrap {
  padding: 12px 12px 4px;
}

.players-list-scroll {
  flex: 1 1 auto;
  min-height: 0;
  max-height: min(560px, calc(100vh - 250px));
  overflow-y: auto;
  overflow-x: hidden;
  padding: 8px 12px 12px !important;
  overscroll-behavior: contain;
}

.players-card {
  display: flex;
  flex-direction: column;
  min-height: 0;
  max-height: 100%;
}

:deep(.v-card) {
  background: linear-gradient(145deg, #151b3d 0%, #1a2351 100%) !important;
  border: 1px solid rgba(255, 107, 53, 0.2);
}

:deep(.v-card-title) {
  background: linear-gradient(135deg, #00838f 0%, #0d47a1 100%) !important;
  font-weight: 700;
}

:deep(.v-list-item) {
  background: linear-gradient(135deg, rgba(21, 27, 61, 0.4) 0%, rgba(26, 35, 81, 0.4) 100%);
  border: 1px solid rgba(13, 71, 161, 0.2);
  margin-bottom: 8px;
  border-radius: 8px;
}

@media (max-width: 600px) {
  :deep(.v-card-title) {
    min-height: 44px;
    padding: 10px 12px;
    font-size: 0.95rem;
  }

  .role-card-wrap {
    padding: 8px 8px 2px;
  }

  .players-list-scroll {
    padding: 6px 8px 10px !important;
  }

  :deep(.v-list-item) {
    margin-bottom: 6px;
    border-radius: 7px;
  }

  :deep(.v-list-item-title) {
    font-size: 0.9rem;
  }

  :deep(.v-list-item-subtitle) {
    font-size: 0.78rem;
  }
}
</style>

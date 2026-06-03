<script setup lang="ts">
import { ref, onMounted, onUnmounted, nextTick, watch } from 'vue'
import { supabase, type Message } from '../lib/supabase'

const props = defineProps<{
  roomId: string
  playerId: string
}>()

const messages = ref<Message[]>([])
const newMessage = ref('')
const messagesContainer = ref<HTMLElement>()
const channel = ref<any>(null)
const channelRoomId = ref<string | null>(null)
const isListening = ref(false)
const speechSupported = ref(false)
const speechError = ref('')
let recognition: any = null
let speechBaseText = ''

const scrollToBottom = () => {
  nextTick(() => {
    if (messagesContainer.value) {
      messagesContainer.value.scrollTop = messagesContainer.value.scrollHeight
    }
  })
}

const scrollBy = (delta: number) => {
  if (messagesContainer.value) {
    messagesContainer.value.scrollBy({ top: delta, behavior: 'smooth' })
  }
}

const scrollUp = () => scrollBy(-120)
const scrollDown = () => scrollBy(120)

const fetchMessages = async () => {
  const { data, error } = await supabase
    .from('messages')
    .select(`
      *,
      players (
        name
      )
    `)
    .eq('room_id', props.roomId)
    .order('created_at', { ascending: true })

  if (error) {
    console.error('Error fetching messages:', error)
    return
  }

  messages.value = data || []
  scrollToBottom()
}

const sendMessage = async () => {
  if (!newMessage.value.trim()) return

  const { error } = await supabase
    .from('messages')
    .insert({
      room_id: props.roomId,
      player_id: props.playerId,
      message: newMessage.value,
      is_system: false,
    })

  if (error) {
    console.error('Error sending message:', error)
    return
  }

  newMessage.value = ''
}

const mergeSpeechText = (base: string, text: string) => {
  const cleanText = text.trim()
  if (!cleanText) return base
  const needsSpace = base.trim().length > 0 && !base.endsWith(' ')
  return `${base}${needsSpace ? ' ' : ''}${cleanText}`
}

const setupSpeechRecognition = () => {
  const SpeechRecognition =
    (window as any).SpeechRecognition || (window as any).webkitSpeechRecognition

  speechSupported.value = !!SpeechRecognition
  if (!SpeechRecognition || recognition) return

  recognition = new SpeechRecognition()
  recognition.lang = 'tr-TR'
  recognition.continuous = false
  recognition.interimResults = true

  recognition.onresult = (event: any) => {
    let finalText = ''
    let interimText = ''

    for (let i = event.resultIndex; i < event.results.length; i++) {
      const transcript = event.results[i]?.[0]?.transcript ?? ''
      if (event.results[i].isFinal) {
        finalText += transcript
      } else {
        interimText += transcript
      }
    }

    if (finalText) {
      newMessage.value = mergeSpeechText(speechBaseText, finalText)
      speechBaseText = newMessage.value
    } else if (interimText) {
      newMessage.value = mergeSpeechText(speechBaseText, interimText)
    }
  }

  recognition.onerror = (event: any) => {
    const error = event?.error
    speechError.value = error === 'not-allowed'
      ? 'Mikrofon izni verilmedi.'
      : 'Mikrofon dinlemesi başlatılamadı.'
    isListening.value = false
  }

  recognition.onend = () => {
    isListening.value = false
  }
}

const toggleSpeechInput = () => {
  speechError.value = ''
  setupSpeechRecognition()

  if (!speechSupported.value || !recognition) {
    speechError.value = 'Bu tarayıcı mikrofonla yazmayı desteklemiyor.'
    return
  }

  if (isListening.value) {
    recognition.stop()
    isListening.value = false
    return
  }

  try {
    speechBaseText = newMessage.value
    recognition.start()
    isListening.value = true
  } catch {
    recognition.stop()
    isListening.value = false
  }
}

const sendSystemMessage = async (message: string) => {
  const text = typeof message === 'string' ? message.trim() : ''
  if (!text || text.includes('undefined')) return

  await supabase
    .from('messages')
    .insert({
      room_id: props.roomId,
      message: text,
      is_system: true,
    })
}

const setupRealtimeSubscription = () => {
  if (channel.value && channelRoomId.value === props.roomId) return

  if (channel.value) {
    supabase.removeChannel(channel.value)
    channel.value = null
    channelRoomId.value = null
  }

  channel.value = supabase
    .channel(`room:${props.roomId}:messages`)
    .on(
      'postgres_changes',
      {
        event: 'INSERT',
        schema: 'public',
        table: 'messages',
        filter: `room_id=eq.${props.roomId}`,
      },
      async (payload: { new: Message }) => {
        const newMsg = payload.new as Message
        if (!messages.value.find(m => m.id === newMsg.id)) {
          if (newMsg.player_id && !newMsg.is_system) {
            const { data: player } = await supabase
              .from('players')
              .select('name')
              .eq('id', newMsg.player_id)
              .single()

            if (player) {
              newMsg.players = { name: player.name }
            }
          }
          messages.value.push(newMsg)
          scrollToBottom()
        }
      }
    )
    .subscribe((status: string) => {
      console.log('Chat subscription status:', status)
    })
  channelRoomId.value = props.roomId
}

onMounted(() => {
  fetchMessages()
  setupRealtimeSubscription()
  setupSpeechRecognition()
})

onUnmounted(() => {
  if (recognition) {
    recognition.stop()
    recognition = null
  }
  if (channel.value) {
    supabase.removeChannel(channel.value)
    channel.value = null
    channelRoomId.value = null
  }
})

watch(() => props.roomId, () => {
  if (channel.value) {
    supabase.removeChannel(channel.value)
    channel.value = null
    channelRoomId.value = null
  }
  fetchMessages()
  setupRealtimeSubscription()
})

defineExpose({
  sendSystemMessage,
})
</script>

<template>
  <v-card elevation="4" class="d-flex flex-column chat-card fill-height">
    <v-card-title class="bg-primary text-white chat-header flex-shrink-0">
      <v-icon start>mdi-chat</v-icon>
      Sohbet
    </v-card-title>

    <div class="messages-wrapper">
      <div class="scroll-controls">
        <v-btn
          icon="mdi-chevron-up"
          size="small"
          variant="tonal"
          color="primary"
          aria-label="Yukarı kaydır"
          @click="scrollUp"
        />
        <v-btn
          icon="mdi-chevron-down"
          size="small"
          variant="tonal"
          color="primary"
          aria-label="Aşağı kaydır"
          @click="scrollDown"
        />
      </div>
      <v-card-text ref="messagesContainer" class="messages-scroll pa-4">
        <div
          v-for="message in messages"
          :key="message.id"
          :class="['message-item', message.is_system ? 'system-message' : 'player-message']"
        >
          <div v-if="message.is_system" class="text-center">
            <v-chip size="small" color="info" variant="tonal">
              {{ message.message }}
            </v-chip>
          </div>
          <div v-else class="d-flex align-start mb-3">
            <v-avatar size="32" color="primary" class="mr-2">
              <v-icon>mdi-account</v-icon>
            </v-avatar>
            <div class="flex-grow-1">
              <div class="d-flex align-center mb-1">
                <span class="text-subtitle-2 font-weight-bold mr-2">
                  {{ message.players?.name || 'Bilinmeyen' }}
                </span>
                <span class="text-caption text-grey">
                  {{ new Date(message.created_at).toLocaleTimeString('tr-TR', {
                    hour: '2-digit',
                    minute: '2-digit'
                  }) }}
                </span>
              </div>
              <div class="message-bubble">
                {{ message.message }}
              </div>
            </div>
          </div>
        </div>
      </v-card-text>
    </div>

    <v-divider />

    <v-card-actions class="pa-3 chat-input flex-shrink-0">
      <div class="chat-compose-row">
      <v-text-field
        v-model="newMessage"
        placeholder="Mesaj yaz..."
        variant="outlined"
        density="compact"
        hide-details
        @keyup.enter="sendMessage"
      />
        <v-tooltip location="top">
          <template #activator="{ props: tooltipProps }">
            <v-btn
              v-bind="tooltipProps"
              :icon="isListening ? 'mdi-microphone-off' : 'mdi-microphone'"
              size="small"
              min-width="40"
              height="40"
              :color="isListening ? 'error' : 'primary'"
              :variant="isListening ? 'flat' : 'tonal'"
              :aria-label="isListening ? 'Mikrofonu kapat' : 'Mikrofonla yaz'"
              class="mic-button"
              @click="toggleSpeechInput"
            />
          </template>
          <span>{{ speechSupported ? (isListening ? 'Dinleme açık' : 'Mikrofonla yaz') : 'Mikrofon desteklenmiyor' }}</span>
        </v-tooltip>
        <v-btn
          icon="mdi-send"
          size="small"
          min-width="40"
          height="40"
          color="primary"
          variant="flat"
          :disabled="!newMessage.trim()"
          aria-label="Mesaj gönder"
          @click="sendMessage"
        />
      </div>
      <div v-if="speechError" class="speech-error">
        {{ speechError }}
      </div>
    </v-card-actions>
  </v-card>
</template>

<style scoped>
.chat-card {
  height: 100%;
  min-height: 0;
  max-height: 100%;
  overflow: hidden;
  display: flex;
  flex-direction: column;
}

.chat-card :deep(.v-card) {
  min-height: 0;
}

.chat-header,
.chat-input {
  flex-shrink: 0;
}

.chat-input {
  flex-direction: column;
  align-items: stretch;
}

.chat-compose-row {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 40px 40px;
  gap: 8px;
  width: 100%;
  align-items: center;
}

.mic-button {
  box-shadow: 0 0 0 1px rgba(100, 181, 246, 0.22);
}

.speech-error {
  margin-top: 6px;
  font-size: 0.75rem;
  color: #ef9a9a;
}

.messages-wrapper {
  display: flex;
  flex: 1 1 0;
  min-height: 0;
  height: 0;
  overflow: hidden;
}

.scroll-controls {
  display: flex;
  flex-direction: column;
  justify-content: center;
  gap: 6px;
  padding: 8px 4px;
  flex-shrink: 0;
  border-right: 1px solid rgba(255, 107, 53, 0.15);
}

.messages-scroll {
  flex: 1 1 0;
  min-height: 0;
  height: 100%;
  overflow-y: auto;
  overflow-x: hidden;
  scroll-behavior: smooth;
}

.message-item {
  margin-bottom: 12px;
  animation: fadeIn 0.3s ease;
}

@keyframes fadeIn {
  from {
    opacity: 0;
    transform: translateY(10px);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}

.system-message {
  text-align: center;
  padding: 8px 0;
}

.system-message :deep(.v-chip) {
  box-shadow: 0 4px 12px rgba(0, 131, 143, 0.4);
  font-weight: 600;
  border: 1px solid rgba(0, 131, 143, 0.3);
}

.message-bubble {
  background: linear-gradient(135deg, rgba(13, 71, 161, 0.2) 0%, rgba(0, 131, 143, 0.2) 100%);
  padding: 8px 12px;
  border-radius: 12px;
  display: inline-block;
  max-width: 80%;
  word-wrap: break-word;
  border: 1px solid rgba(255, 107, 53, 0.2);
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.3);
}

@media (max-width: 600px) {
  .chat-header {
    min-height: 44px;
    padding: 10px 12px;
    font-size: 0.95rem;
  }

  .messages-scroll {
    padding: 10px !important;
  }

  .scroll-controls {
    padding: 6px 3px;
  }

  .message-bubble {
    max-width: 100%;
    font-size: 0.86rem;
  }

  .chat-input {
    padding: 10px !important;
  }

  .chat-compose-row {
    grid-template-columns: minmax(0, 1fr) 38px 38px;
    gap: 6px;
  }
}

:deep(.v-card) {
  background: linear-gradient(145deg, #151B3D 0%, #1A2351 100%) !important;
  border: 1px solid rgba(255, 107, 53, 0.2);
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4), 0 0 20px rgba(13, 71, 161, 0.3);
}

:deep(.v-card-title) {
  background: linear-gradient(135deg, #0D47A1 0%, #00838F 100%) !important;
  text-shadow: 0 2px 8px rgba(0, 0, 0, 0.5);
  font-weight: 700;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
}

:deep(.v-card-text) {
  background: rgba(10, 14, 39, 0.4);
  backdrop-filter: blur(10px);
}

:deep(.v-avatar) {
  box-shadow: 0 4px 12px rgba(13, 71, 161, 0.5);
}

:deep(.v-divider) {
  border-color: rgba(255, 107, 53, 0.3);
  border-width: 2px;
}
</style>

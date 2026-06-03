<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { supabase, supabaseEnabled, isSupabaseConfigured, markSupabaseConnected, type Player, type Room } from '../lib/supabase'
import SetupBanner from '../components/SetupBanner.vue'

const router = useRouter()
const playerName = ref('')
const roomCode = ref('')
const newRoomName = ref('')
const maxPlayers = ref(8)
const rooms = ref<Room[]>([])
const loading = ref(false)
const createRoomDialog = ref(false)
const joinRoomDialog = ref(false)
const rulesOpen = ref<number | undefined>(undefined)
const snackbar = ref({ show: false, text: '', color: 'error' as 'error' | 'warning' | 'success' })
let roomsRefreshTimer: ReturnType<typeof setInterval> | null = null

const normalizedRoomCode = computed(() => roomCode.value.trim().toUpperCase().replace(/\s+/g, ''))
const canUseOnline = computed(() => isSupabaseConfigured.value && supabaseEnabled)
const canCreateRoom = computed(() => canUseOnline.value && !!playerName.value.trim() && !!newRoomName.value.trim())

const showMessage = (text: string, color: 'error' | 'warning' | 'success' = 'error') => {
  snackbar.value = { show: true, text, color }
}

const generateRoomCode = () => {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
  let code = ''
  for (let i = 0; i < 6; i++) {
    code += chars.charAt(Math.floor(Math.random() * chars.length))
  }
  return code
}

const fetchRooms = async () => {
  if (!supabaseEnabled) {
    rooms.value = []
    return
  }

  const { data, error } = await supabase
    .from('rooms')
    .select('*')
    .in('status', ['waiting', 'playing'])
    .order('created_at', { ascending: false })
    .limit(6)

  if (error) {
    console.error('Error fetching rooms:', error)
    return
  }

  markSupabaseConnected()
  rooms.value = data || []
}

const createRoom = async () => {
  if (!playerName.value.trim() || !newRoomName.value.trim()) return
  if (!canUseOnline.value) {
    showMessage('Supabase ayarlı değil. Online oda oluşturmak için .env.local dosyasını ayarlayın.', 'warning')
    return
  }

  loading.value = true
  try {
    let room: Room | null = null
    let lastError: unknown = null

    for (let attempt = 0; attempt < 3 && !room; attempt++) {
      const code = generateRoomCode()
      const { data, error } = await supabase
        .from('rooms')
        .insert({
          room_code: code,
          name: newRoomName.value.trim(),
          status: 'waiting',
          max_players: maxPlayers.value,
        })
        .select()
        .single()

      if (!error) room = data
      lastError = error
    }

    if (!room) throw lastError

    const { data: player, error: playerError } = await supabase
      .from('players')
      .insert({
        room_id: room.id,
        name: playerName.value.trim(),
        is_host: true,
      })
      .select()
      .single()

    if (playerError) throw playerError

    sessionStorage.setItem('playerName', playerName.value.trim())
    sessionStorage.setItem('playerId', player.id)
    router.push(`/room/${room.room_code}`)
  } catch (error) {
    console.error('Error creating room:', error)
    showMessage('Oda oluşturulamadı. Supabase tablo kurulumunu ve bağlantıyı kontrol edin.')
  } finally {
    loading.value = false
  }
}

const joinRoom = async (code: string) => {
  const cleanCode = code.trim().toUpperCase().replace(/\s+/g, '')
  const cleanPlayerName = playerName.value.trim()

  if (!cleanPlayerName) {
    roomCode.value = cleanCode
    joinRoomDialog.value = true
    return
  }
  if (!canUseOnline.value) {
    showMessage('Supabase ayarlı değil. Online odaya katılmak için .env.local dosyasını ayarlayın.', 'warning')
    return
  }
  if (!cleanCode) return

  loading.value = true
  try {
    const { data: room, error: roomError } = await supabase
      .from('rooms')
      .select('*')
      .eq('room_code', cleanCode)
      .maybeSingle()

    if (roomError) throw roomError
    if (!room) {
      showMessage('Bu kodla bir oda bulunamadı.', 'warning')
      return
    }

    const { data: players } = await supabase
      .from('players')
      .select('*')
      .eq('room_id', room.id)

    const existingPlayer = (players as Player[] | null)?.find(
      p => p.name.trim().toLocaleLowerCase('tr-TR') === cleanPlayerName.toLocaleLowerCase('tr-TR')
    )

    if (room.status !== 'waiting') {
      if (!existingPlayer) {
        showMessage('Oyun başladı. Sadece daha önce bu odada olan oyuncular geri katılabilir.', 'warning')
        return
      }

      sessionStorage.setItem('playerName', existingPlayer.name)
      sessionStorage.setItem('playerId', existingPlayer.id)
      router.push(`/room/${cleanCode}`)
      return
    }

    if (existingPlayer) {
      sessionStorage.setItem('playerName', existingPlayer.name)
      sessionStorage.setItem('playerId', existingPlayer.id)
      router.push(`/room/${cleanCode}`)
      return
    }

    if (players && players.length >= room.max_players) {
      showMessage('Oda dolu!', 'warning')
      return
    }

    const { data: player, error: playerError } = await supabase
      .from('players')
      .insert({
        room_id: room.id,
        name: cleanPlayerName,
        is_host: false,
      })
      .select()
      .single()

    if (playerError) throw playerError

    sessionStorage.setItem('playerName', cleanPlayerName)
    sessionStorage.setItem('playerId', player.id)
    router.push(`/room/${cleanCode}`)
  } catch (error) {
    console.error('Error joining room:', error)
    showMessage('Odaya katılamadınız. Kod, bağlantı veya tablo kurulumunu kontrol edin.')
  } finally {
    loading.value = false
  }
}

const joinRoomWithCode = async () => {
  if (!normalizedRoomCode.value) return
  await joinRoom(normalizedRoomCode.value)
  if (!loading.value) joinRoomDialog.value = false
}

onMounted(() => {
  fetchRooms()
  const savedName = sessionStorage.getItem('playerName')
  if (savedName) playerName.value = savedName
  if (supabaseEnabled) roomsRefreshTimer = setInterval(fetchRooms, 5000)
})

onUnmounted(() => {
  if (roomsRefreshTimer) clearInterval(roomsRefreshTimer)
})
</script>

<template>
  <div class="home-page">
    <div class="home-stage">
      <SetupBanner />

      <section class="hero-panel">
        <div class="hero-copy">
          <div class="eyebrow">Gizli kimlikli strateji oyunu</div>
          <h1 class="ghost-logo" aria-label="GHOST">
            <span>G</span><span>H</span><span>O</span><span>S</span><span>T</span>
          </h1>
          <p>
            Oyuncular konuşur, oylar, kartları açar. Sadıklar düzeni kurmaya,
            hainler kaosu büyütmeye çalışır.
          </p>
        </div>

        <div class="quick-card">
          <v-text-field
            v-model="playerName"
            label="Oyuncu adı"
            variant="outlined"
            density="comfortable"
            hide-details
            prepend-inner-icon="mdi-account"
            class="name-field"
          />

          <div class="primary-actions">
            <v-btn
              color="primary"
              size="large"
              block
              prepend-icon="mdi-plus-circle"
              :disabled="!playerName.trim() || !canUseOnline"
              @click="createRoomDialog = true"
            >
              Oda Kur
            </v-btn>
            <v-btn
              color="secondary"
              size="large"
              block
              prepend-icon="mdi-login"
              :disabled="!playerName.trim() || !canUseOnline"
              @click="joinRoomDialog = true"
            >
              Koda Katıl
            </v-btn>
          </div>

          <div class="quick-status">
            <v-icon size="18" :color="canUseOnline ? 'success' : 'warning'">
              {{ canUseOnline ? 'mdi-check-circle' : 'mdi-alert-circle' }}
            </v-icon>
            <span>{{ canUseOnline ? 'Online oyun hazır' : 'Supabase bağlantısı bekleniyor' }}</span>
          </div>
        </div>
      </section>

      <section class="content-grid">
        <div class="rooms-panel">
          <div class="section-heading">
            <div>
              <span>Aktif Odalar</span>
              <small>{{ rooms.length ? `${rooms.length} oda listeleniyor` : 'Henüz oda yok' }}</small>
            </div>
            <v-btn
              icon="mdi-refresh"
              variant="text"
              size="small"
              :loading="loading"
              aria-label="Odaları yenile"
              @click="fetchRooms"
            />
          </div>

          <div v-if="rooms.length" class="rooms-list">
            <article v-for="room in rooms" :key="room.id" class="room-row">
              <div class="room-main">
                <strong>{{ room.name }}</strong>
                <span>{{ room.room_code }} · {{ room.status === 'waiting' ? 'Bekliyor' : 'Oyunda' }}</span>
              </div>
              <v-btn
                size="small"
                color="primary"
                variant="tonal"
                :disabled="!playerName.trim() || !canUseOnline"
                @click="joinRoom(room.room_code)"
              >
                Katıl
              </v-btn>
            </article>
          </div>

          <div v-else class="empty-state">
            <v-icon size="34">mdi-door-open</v-icon>
            <p>
              {{ canUseOnline ? 'Açık oda yok. İlk masayı siz kurun.' : 'Bağlantı kurulmadan odalar listelenemez.' }}
            </p>
          </div>
        </div>

        <v-expansion-panels v-model="rulesOpen" variant="accordion" class="rules-panel">
          <v-expansion-panel>
            <v-expansion-panel-title>
              <v-icon start size="small">mdi-book-open-variant</v-icon>
              Kısa Kurallar
            </v-expansion-panel-title>
            <v-expansion-panel-text>
              <div class="rules-list">
                <article class="rule-card">
                  <v-icon size="20">mdi-account-group</v-icon>
                  <div>
                    <strong>Takımlar</strong>
                    <p>Hainler ve Özel Ajan aynı takım sayılır. Diğer herkes Sadık takımındadır.</p>
                  </div>
                </article>
                <article class="rule-card">
                  <v-icon size="20">mdi-incognito</v-icon>
                  <div>
                    <strong>Rol dağılımı</strong>
                    <p>5-6 kişi: 1 Hain, 1 Özel Ajan. 7-8 kişi: 2 Hain, 1 Özel Ajan. 9-10 kişi: 3 Hain, 1 Özel Ajan. Kalanlar Sadık olur.</p>
                  </div>
                </article>
                <article class="rule-card">
                  <v-icon size="20">mdi-eye-off</v-icon>
                  <div>
                    <strong>Gizli bilgi</strong>
                    <p>Hainler Özel Ajanı görebilir. Özel Ajan Hainleri göremez. Rol bakma gücünde Özel Ajan sadece Hain gibi görünür.</p>
                  </div>
                </article>
                <article class="rule-card">
                  <v-icon size="20">mdi-cards</v-icon>
                  <div>
                    <strong>Kazanma hedefi</strong>
                    <p>Sadıklar Safe kartlarını, Hain takımı Kaos kartlarını tamamlamaya çalışır. 5-6 kişide 5, 7-8 kişide 7, 9-10 kişide 9 kart hedefe ulaşırsa oyun biter.</p>
                  </div>
                </article>
                <article class="rule-card">
                  <v-icon size="20">mdi-timer-sand</v-icon>
                  <div>
                    <strong>Tur akışı</strong>
                    <p>Önce tartışma yapılır. Sonra Yetkili seçilir. Yetkili ve Danışman kart seçer, seçilen kart açılır.</p>
                  </div>
                </article>
                <article class="rule-card">
                  <v-icon size="20">mdi-alert-octagon</v-icon>
                  <div>
                    <strong>Kaos güçleri</strong>
                    <p>Toplam 2. Kaos açılınca Yetkili 15 saniye içinde bir kişinin rolüne bakabilir. Toplam 3. Kaos açılınca Yetkili 15 saniye içinde bir kişiyi oyun dışı bırakabilir.</p>
                  </div>
                </article>
                <article class="rule-card">
                  <v-icon size="20">mdi-flag-checkered</v-icon>
                  <div>
                    <strong>Özel Ajan kuralı</strong>
                    <p>3. Kaos kartından sonra Özel Ajan Yetkili seçilirse Hainler hemen kazanır. Özel Ajan elenirse Sadıklar hemen kazanır.</p>
                  </div>
                </article>
              </div>
            </v-expansion-panel-text>
          </v-expansion-panel>
        </v-expansion-panels>
      </section>
    </div>

    <v-dialog v-model="createRoomDialog" max-width="440">
      <v-card class="dialog-card">
        <v-card-title>Yeni Oda</v-card-title>
        <v-card-text>
          <v-text-field v-model="newRoomName" label="Oda adı" variant="outlined" />
          <v-slider v-model="maxPlayers" label="Maksimum oyuncu" :min="5" :max="10" :step="1" thumb-label />
        </v-card-text>
        <v-card-actions>
          <v-spacer />
          <v-btn @click="createRoomDialog = false">İptal</v-btn>
          <v-btn color="primary" :disabled="!canCreateRoom" :loading="loading" @click="createRoom">
            Oluştur
          </v-btn>
        </v-card-actions>
      </v-card>
    </v-dialog>

    <v-dialog v-model="joinRoomDialog" max-width="440">
      <v-card class="dialog-card">
        <v-card-title>Odaya Katıl</v-card-title>
        <v-card-text>
          <v-text-field
            v-model="roomCode"
            label="Oda kodu"
            variant="outlined"
            maxlength="6"
            counter
            autofocus
            @keyup.enter="joinRoomWithCode"
          />
        </v-card-text>
        <v-card-actions>
          <v-spacer />
          <v-btn @click="joinRoomDialog = false">İptal</v-btn>
          <v-btn color="primary" :disabled="!normalizedRoomCode" :loading="loading" @click="joinRoomWithCode">
            Katıl
          </v-btn>
        </v-card-actions>
      </v-card>
    </v-dialog>

    <v-snackbar v-model="snackbar.show" :color="snackbar.color" :timeout="6000" location="top">
      {{ snackbar.text }}
      <template #actions>
        <v-btn variant="text" @click="snackbar.show = false">Kapat</v-btn>
      </template>
    </v-snackbar>
  </div>
</template>

<style scoped>
.home-page {
  min-height: 100%;
  overflow: auto;
  background:
    radial-gradient(circle at 15% 12%, rgba(0, 150, 136, 0.18), transparent 30%),
    radial-gradient(circle at 84% 18%, rgba(255, 112, 67, 0.18), transparent 34%),
    linear-gradient(145deg, #08111f 0%, #111827 48%, #15121f 100%);
}

.home-stage {
  width: min(1120px, calc(100% - 32px));
  min-height: calc(100vh - 64px);
  margin: 0 auto;
  padding: 32px 0;
  display: flex;
  flex-direction: column;
  gap: 18px;
}

.hero-panel {
  display: grid;
  grid-template-columns: minmax(0, 1.25fr) minmax(320px, 0.75fr);
  gap: 20px;
  align-items: stretch;
  padding: 28px;
  min-height: 360px;
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 8px;
  background:
    linear-gradient(120deg, rgba(10, 18, 32, 0.86), rgba(12, 28, 42, 0.78)),
    url('https://images.unsplash.com/photo-1519608487953-e999c86e7455?auto=format&fit=crop&w=1400&q=80');
  background-size: cover;
  background-position: center;
  box-shadow: 0 22px 60px rgba(0, 0, 0, 0.35);
}

.hero-copy {
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
  max-width: 680px;
}

.eyebrow {
  width: fit-content;
  padding: 6px 10px;
  border: 1px solid rgba(255, 255, 255, 0.18);
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.08);
  color: rgba(255, 255, 255, 0.78);
  font-size: 0.78rem;
  font-weight: 700;
  text-transform: uppercase;
}

.hero-copy h1 {
  margin: 18px 0 10px;
  font-size: clamp(3.2rem, 9vw, 7rem);
  line-height: 0.9;
  font-weight: 900;
}

.ghost-logo {
  display: flex;
  flex-wrap: wrap;
  gap: clamp(4px, 1.2vw, 12px);
  width: fit-content;
  color: #fff;
  letter-spacing: 0;
  filter: drop-shadow(0 18px 28px rgba(0, 0, 0, 0.55));
}

.ghost-logo span {
  display: inline-grid;
  place-items: center;
  min-width: clamp(48px, 8.5vw, 92px);
  min-height: clamp(58px, 9vw, 104px);
  padding: 0 8px;
  border: 1px solid rgba(255, 255, 255, 0.18);
  border-radius: 8px;
  background:
    linear-gradient(180deg, rgba(255, 255, 255, 0.16), rgba(255, 255, 255, 0.03)),
    linear-gradient(145deg, rgba(0, 131, 143, 0.38), rgba(255, 107, 53, 0.18));
  text-shadow:
    0 0 16px rgba(255, 255, 255, 0.35),
    0 4px 14px rgba(0, 0, 0, 0.65);
  box-shadow:
    inset 0 1px 0 rgba(255, 255, 255, 0.24),
    0 10px 28px rgba(0, 0, 0, 0.34);
}

.ghost-logo span:nth-child(3) {
  color: #ffb38a;
  border-color: rgba(255, 179, 138, 0.35);
}

.hero-copy p {
  max-width: 560px;
  margin: 0;
  color: rgba(255, 255, 255, 0.78);
  font-size: 1.08rem;
  line-height: 1.55;
}

.quick-card,
.rooms-panel {
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 8px;
  background: rgba(8, 13, 24, 0.76);
  backdrop-filter: blur(14px);
  box-shadow: 0 18px 40px rgba(0, 0, 0, 0.28);
}

.quick-card {
  align-self: end;
  padding: 18px;
  display: flex;
  flex-direction: column;
  gap: 14px;
}

.primary-actions {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 10px;
}

.quick-status {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 28px;
  color: rgba(255, 255, 255, 0.68);
  font-size: 0.9rem;
}

.content-grid {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(300px, 380px);
  gap: 18px;
}

.rooms-panel {
  padding: 18px;
  min-height: 260px;
}

.section-heading {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 14px;
}

.section-heading span {
  display: block;
  color: #fff;
  font-size: 1.05rem;
  font-weight: 800;
}

.section-heading small {
  color: rgba(255, 255, 255, 0.52);
  font-size: 0.78rem;
}

.rooms-list {
  display: grid;
  gap: 10px;
}

.room-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 14px;
  padding: 12px;
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 8px;
  background: rgba(255, 255, 255, 0.045);
}

.room-main {
  min-width: 0;
}

.room-main strong,
.room-main span {
  display: block;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.room-main strong {
  color: #fff;
  font-size: 0.95rem;
}

.room-main span {
  color: rgba(255, 255, 255, 0.52);
  font-size: 0.78rem;
}

.empty-state {
  min-height: 176px;
  display: grid;
  place-items: center;
  align-content: center;
  gap: 10px;
  color: rgba(255, 255, 255, 0.55);
  text-align: center;
}

.empty-state p {
  margin: 0;
}

.rules-panel :deep(.v-expansion-panel) {
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 8px !important;
  background: rgba(8, 13, 24, 0.76) !important;
  overflow: hidden;
}

.rules-panel :deep(.v-expansion-panel-title) {
  min-height: 56px;
  font-weight: 800;
}

.rules-list {
  display: grid;
  gap: 8px;
  color: rgba(255, 255, 255, 0.74);
  font-size: 0.9rem;
  line-height: 1.42;
}

.rule-card {
  display: grid;
  grid-template-columns: 28px minmax(0, 1fr);
  gap: 10px;
  padding: 10px;
  border: 1px solid rgba(255, 255, 255, 0.09);
  border-radius: 8px;
  background: rgba(255, 255, 255, 0.045);
}

.rule-card :deep(.v-icon) {
  color: #ffb38a;
  margin-top: 2px;
}

.rule-card strong {
  display: block;
  margin-bottom: 3px;
  color: #fff;
  font-size: 0.9rem;
}

.rule-card p {
  margin: 0;
}

.dialog-card {
  border-radius: 8px !important;
}

@media (max-width: 860px) {
  .home-stage {
    width: min(100% - 20px, 640px);
    padding: 16px 0;
  }

  .hero-panel,
  .content-grid {
    grid-template-columns: 1fr;
  }

  .hero-panel {
    min-height: 0;
    padding: 20px;
  }

  .quick-card {
    align-self: stretch;
  }
}

@media (max-width: 520px) {
  .primary-actions {
    grid-template-columns: 1fr;
  }

  .hero-copy h1 {
    font-size: 3.2rem;
  }

  .ghost-logo span {
    min-width: 42px;
    min-height: 52px;
  }

  .hero-copy p {
    font-size: 0.98rem;
  }
}
</style>

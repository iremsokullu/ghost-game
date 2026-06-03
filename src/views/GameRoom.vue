<script setup lang="ts">
import { ref, computed, watch, onMounted, onUnmounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import {
  supabase,
  supabaseEnabled,
  isSupabaseConfigured,
  markSupabaseConnected,
  type Room,
  type Player,
  type GameState,
  type Vote,
} from '../lib/supabase'
import ChatPanel from '../components/ChatPanel.vue'
import PlayersList from '../components/PlayersList.vue'
import PhaseTimer from '../components/PhaseTimer.vue'
import SetupBanner from '../components/SetupBanner.vue'
import { playCardDraw, playCardReveal, playGameEnd, playGameStart } from '../lib/audio'

const route = useRoute()
const router = useRouter()
const roomCode = route.params.roomCode as string

const room = ref<Room | null>(null)
const players = ref<Player[]>([])
const gameState = ref<GameState | null>(null)
const currentPlayerId = ref('')
const loading = ref(true)
const selectedCardIndex = ref<number | null>(null)
const selectedVotePlayerId = ref<string | null>(null)
const votes = ref<Vote[]>([])
const rolePeekUsed = ref(false)
const killUsed = ref(false)
/** Oylama türü (yerel; DB bayraklarıyla senkron) */
const votingPurpose = ref<'authority' | 'role_peek' | 'kill'>('authority')
const chatPanelRef = ref<InstanceType<typeof ChatPanel>>()
let playersChannel: any
let roomChannel: any
let gameStateChannel: any
let votesChannel: any
let isRefreshingGameState = false
let isRealtimeRefreshTick = false
let isProcessingTurn = false
let lastGameStateUpdate = 0
let phaseAdvanceInFlight = false
const PHASE_ADVANCE_MAX_MS = 45_000
let phaseAdvanceStartedAt = 0
let phaseSyncInterval: ReturnType<typeof setInterval> | null = null
const REVEAL_STUCK_MS = 10_000

const snackbar = ref({ show: false, text: '', color: 'error' as 'error' | 'warning' | 'success' })
const supabaseBlocked = computed(() => !isSupabaseConfigured.value)
const lastSoundState = ref({
  safe: 0,
  kaos: 0,
  status: null as Room['status'] | null,
  winner: null as Room['winning_team'] | null,
})

const playerName = (name?: string | null, fallback = 'Oyuncu') => {
  const n = name?.trim()
  return n && n !== 'undefined' ? n : fallback
}

/** DB'de eksik olabilecek sütunlar — güncelleme hata verirse patch'ten çıkarılır */
const OPTIONAL_STATE_COLUMNS = new Set([
  'advisor_can_investigate',
  'advisor_can_view_role',
  'card_peeker_player_id',
  'viewed_player_id',
])

const logDbError = (context: string, error: { message?: string } | null | undefined) => {
  if (error) console.error(`[GameRoom] ${context}:`, error.message ?? error)
}

const showDbToast = (
  context: string,
  error?: { message?: string } | null,
  color: 'error' | 'warning' = 'error'
) => {
  const detail = error?.message ? `: ${error.message}` : ''
  snackbar.value = { show: true, text: `${context}${detail}`, color }
  logDbError(context, error)
}

const isMissingColumnError = (error: { message?: string } | null | undefined) =>
  !!error?.message?.match(/column|schema cache|does not exist/i)

const extractMissingColumn = (error: { message?: string } | null | undefined) => {
  const m = error?.message?.match(/['"]?(\w+)['"]?\s+column/i)
    ?? error?.message?.match(/column\s+['"]?(\w+)['"]?/i)
  return m?.[1]
}

const stripMissingColumnFromPatch = (
  patch: Record<string, unknown>,
  error: { message?: string } | null | undefined
) => {
  const out = { ...patch }
  const col = extractMissingColumn(error)
  if (col && (OPTIONAL_STATE_COLUMNS.has(col) || col in out)) {
    delete out[col]
    return out
  }
  for (const key of OPTIONAL_STATE_COLUMNS) {
    delete out[key]
  }
  return out
}

const normalizeGameState = (raw: Record<string, unknown>): GameState => ({
  ...(raw as unknown as GameState),
  cards_in_deck: typeof raw.cards_in_deck === 'string'
    ? JSON.parse(raw.cards_in_deck as string)
    : (raw.cards_in_deck as string[]) ?? [],
  selected_cards: typeof raw.selected_cards === 'string'
    ? JSON.parse(raw.selected_cards as string)
    : (raw.selected_cards as string[]) ?? [],
  advisor_cards: typeof raw.advisor_cards === 'string'
    ? JSON.parse(raw.advisor_cards as string)
    : (raw.advisor_cards as string[]) ?? [],
  consecutive_kaos_count: Number(raw.consecutive_kaos_count ?? 0),
  advisor_can_view_role: raw.advisor_can_view_role === true,
  advisor_can_investigate: raw.advisor_can_investigate === true,
  safe_cards_played: Number(raw.safe_cards_played ?? 0),
  kaos_cards_played: Number(raw.kaos_cards_played ?? 0),
  current_phase_number: Number(raw.current_phase_number ?? 1),
  current_turn: Number(raw.current_turn ?? 1),
})

const isRevealStuck = () => {
  if (gameState.value?.game_phase !== 'reveal' || !gameState.value.phase_end_time) return false
  return Date.now() - new Date(gameState.value.phase_end_time).getTime() > REVEAL_STUCK_MS
}

/** Faz korumalı güncelleme; eksik sütunda slim patch; 0 satırda fetch ile idempotent kontrol */
const updateGameState = async (
  patch: Record<string, unknown>,
  context: string,
  phaseGuard?: string,
  options?: { skipPhaseGuard?: boolean }
): Promise<boolean> => {
  if (!room.value) return false

  const runUpdate = async (p: Record<string, unknown>, guard?: string) => {
    let query = supabase.from('game_states').update(p).eq('room_id', room.value!.id)
    if (guard && !options?.skipPhaseGuard) query = query.eq('game_phase', guard)
    return query.select('id')
  }

  let attemptPatch = { ...patch }
  let { data, error } = await runUpdate(attemptPatch, phaseGuard)

  let columnRetries = 0
  while (error && isMissingColumnError(error) && columnRetries < 6) {
    const slim = stripMissingColumnFromPatch(attemptPatch, error)
    if (JSON.stringify(slim) === JSON.stringify(attemptPatch)) break
    attemptPatch = slim
    columnRetries += 1
    ;({ data, error } = await runUpdate(attemptPatch, phaseGuard))
  }

  if (error) {
    const needsMigration = /game_phase|valid_phase|check constraint/i.test(error.message ?? '')
    showDbToast(
      needsMigration
        ? `${context} — Supabase SQL Editor'da RUN_IN_SUPABASE_SQL_EDITOR.sql çalıştırın`
        : context,
      error,
      needsMigration ? 'warning' : 'error'
    )
    return false
  }

  if (phaseGuard && !options?.skipPhaseGuard && (!data || data.length === 0)) {
    await fetchGameStateOnly()
    return false
  }

  return true
}

const fetchGameStateOnly = async () => {
  if (!room.value || room.value.status !== 'playing') return

  const { data: stateData, error } = await supabase
    .from('game_states')
    .select('*')
    .eq('room_id', room.value.id)
    .maybeSingle()

  if (error) {
    logDbError('fetchGameStateOnly', error)
    return
  }

  if (!stateData) return

  gameState.value = normalizeGameState(stateData as Record<string, unknown>)
}

const isTurnAlreadyAdvanced = (expectedTurn: number) =>
  gameState.value?.game_phase === 'discussion' &&
  (gameState.value?.current_turn ?? 0) >= expectedTurn

const beginPhaseAdvance = () => {
  if (phaseAdvanceInFlight) {
    if (Date.now() - phaseAdvanceStartedAt < PHASE_ADVANCE_MAX_MS) return false
    console.warn('[GameRoom] phaseAdvanceInFlight sıfırlandı (takılı kalmış olabilir)')
  }
  phaseAdvanceInFlight = true
  phaseAdvanceStartedAt = Date.now()
  return true
}

const endPhaseAdvance = () => {
  phaseAdvanceInFlight = false
  phaseAdvanceStartedAt = 0
}

const currentPlayer = computed(() =>
  players.value.find(p => p.id === currentPlayerId.value)
)

const isHost = computed(() => currentPlayer.value?.is_host || false)
const isGameWaiting = computed(() => room.value?.status === 'waiting')
const isGamePlaying = computed(() => room.value?.status === 'playing')
const isGameFinished = computed(() => room.value?.status === 'finished')
const canStartGame = computed(() =>
  isHost.value &&
  players.value.length >= 5 &&
  room.value?.status === 'waiting'
)

// Kazanma hedefi: 5-6 oyuncu → 5 kart, 7-8 → 7 kart, 9-10 → 9 kart
const winTarget = computed(() => {
  const playerCount = players.value.length
  if (playerCount <= 6) return 5
  if (playerCount <= 8) return 7
  return 9
})

const winnerBanner = computed(() => {
  if (!isGameFinished.value || !room.value?.winning_team) return null

  const isSadikWin = room.value.winning_team === 'sadik'
  const safeCount = gameState.value?.safe_cards_played ?? 0
  const kaosCount = gameState.value?.kaos_cards_played ?? 0
  const cardWin =
  safeCount >= winTarget.value
    ? 'safe'
    : kaosCount >= winTarget.value
      ? 'kaos'
      : null

  return {
    title: isSadikWin ? 'Sadıklar kazandı!' : 'Hainler kazandı!',
    subtitle: cardWin === 'safe'
      ? `${safeCount} Safe kartı açıldı (hedef: ${winTarget.value})`
      : cardWin === 'kaos'
        ? `${kaosCount} Kaos kartı açıldı (hedef: ${winTarget.value})`
        : isSadikWin
          ? 'Sadıklar zafer koşulunu sağladı'
          : 'Hainler zafer koşulunu sağladı',
    color: isSadikWin ? 'success' : 'error',
  }
})

const isCurrentAuthority = computed(() =>
  gameState.value?.current_authority_player_id === currentPlayerId.value
)

const isCurrentAdvisor = computed(() =>
  gameState.value?.current_advisor_player_id === currentPlayerId.value
)

const currentAuthorityPlayer = computed(() =>
  players.value.find(p => p.id === gameState.value?.current_authority_player_id)
)

const currentAdvisorPlayer = computed(() =>
  players.value.find(p => p.id === gameState.value?.current_advisor_player_id)
)

/** Eski akış: artık 2./3. Kaos'ta oylama yok; yalnızca normal Yetkili oylaması */
const isRolePeekVoteMode = computed(() => false)

const isKillVoteMode = computed(() => false)

const syncVotingPurposeFromState = (state: GameState) => {
  if (state.game_phase === 'voting' && state.advisor_can_view_role) {
    votingPurpose.value = 'role_peek'
  } else if (state.game_phase === 'voting' && state.advisor_can_investigate) {
    votingPurpose.value = 'kill'
  } else {
    votingPurpose.value = 'authority'
  }
}

const isAuthorityRoleViewPhase = computed(
  () => gameState.value?.game_phase === 'authority_view_role'
)

const isAuthorityKillPhase = computed(
  () => gameState.value?.game_phase === 'authority_kill'
)

const canAuthorityPeekRole = computed(
  () => isAuthorityRoleViewPhase.value && isCurrentAuthority.value
)

const canAuthorityKill = computed(
  () => isAuthorityKillPhase.value && isCurrentAuthority.value
)

const isKillVoter = computed(
  () =>
    gameState.value?.card_peeker_player_id === currentPlayerId.value &&
    gameState.value?.game_phase === 'player_kill'
)

const killVoterPlayer = computed(() =>
  players.value.find(p => p.id === gameState.value?.card_peeker_player_id)
)

const votingCandidates = computed(() => {
  const alive = players.value.filter(p => p.is_alive)
  if (isRolePeekVoteMode.value || isKillVoteMode.value) return alive
  return alive.filter(p => p.id !== currentPlayerId.value)
})

const isPhaseExpired = () => {
  if (!gameState.value?.phase_end_time) return false
  return new Date(gameState.value.phase_end_time).getTime() <= Date.now()
}

const hasVoted = computed(() => {
  if (!gameState.value) return false
  return votes.value.some(v =>
    v.voter_player_id === currentPlayerId.value &&
    v.turn_number === gameState.value?.current_turn
  )
})

const aliveVoters = computed(() => players.value.filter(p => p.is_alive))

const allAlivePlayersVoted = computed(() => {
  if (!gameState.value || gameState.value.game_phase !== 'voting') return false
  if (aliveVoters.value.length === 0) return false
  const voterIds = new Set(
    votes.value
      .filter(v => v.turn_number === gameState.value?.current_turn)
      .map(v => v.voter_player_id)
  )
  return aliveVoters.value.every(p => voterIds.has(p.id))
})

const voteResults = computed(() => {
  if (!gameState.value) return []

  const currentTurnVotes = votes.value.filter(v => v.turn_number === gameState.value?.current_turn)
  const voteCounts: Record<string, number> = {}

  currentTurnVotes.forEach(vote => {
    if (vote.voted_for_player_id) {
      voteCounts[vote.voted_for_player_id] = (voteCounts[vote.voted_for_player_id] || 0) + 1
    }
  })

  return Object.entries(voteCounts).map(([playerId, count]) => ({
    player: players.value.find(p => p.id === playerId),
    votes: count
  })).sort((a, b) => b.votes - a.votes)
})

const availableCards = computed(() => {
  if (!gameState.value) return []

  if (gameState.value.game_phase === 'authority_selection' && isCurrentAuthority.value) {
    return gameState.value.selected_cards
  }

  if (gameState.value.game_phase === 'advisor_selection' && isCurrentAdvisor.value) {
    return gameState.value.advisor_cards
  }

  return []
})

const chooseCardIndex = (index: number) => {
  selectedCardIndex.value = index
  playCardDraw()
}

const generateDeck = () => {
  // Safe (Safa) daha az, Kaos biraz daha fazla — fark hissedilir ama abartılı değil (6 / 11)
  const deck = [
    ...Array(6).fill('safe'),
    ...Array(11).fill('kaos'),
  ]
  return deck.sort(() => Math.random() - 0.5)
}

const assignRoles = (): NonNullable<Player['role']>[] => {
  const playerCount = players.value.length
  const hainCount = playerCount <= 6 ? 1 : playerCount <= 8 ? 2 : 3
  const sadikCount = Math.max(0, playerCount - hainCount - 1)
  const roles: NonNullable<Player['role']>[] = [
    ...Array(sadikCount).fill('sadik'),
    ...Array(hainCount).fill('hain'),
    'ajan',
  ]

  return roles.sort(() => Math.random() - 0.5)
}

const getPhaseEndTime = (seconds: number) => {
  const date = new Date()
  date.setSeconds(date.getSeconds() + seconds)
  return date.toISOString()
}

const startGame = async () => {
  if (!room.value || !isHost.value) return

  loading.value = true

  try {
    const roles = assignRoles()
    const deck = generateDeck()
    const orderedPlayers = [...players.value].sort(
      (a, b) => new Date(a.joined_at).getTime() - new Date(b.joined_at).getTime()
    )

    if (roles.length !== orderedPlayers.length) {
      throw new Error(`Rol dağıtımı oyuncu sayısıyla eşleşmedi: ${roles.length}/${orderedPlayers.length}`)
    }

    for (let i = 0; i < orderedPlayers.length; i++) {
      const { error: roleErr } = await supabase
        .from('players')
        .update({ role: roles[i] })
        .eq('id', orderedPlayers[i].id)
      if (roleErr) throw roleErr
    }

    await supabase
      .from('rooms')
      .update({
        status: 'playing',
        started_at: new Date().toISOString(),
      })
      .eq('id', room.value.id)

    await supabase
      .from('game_states')
      .insert({
        room_id: room.value.id,
        current_turn: 1,
        current_authority_player_id: null,
        current_advisor_player_id: null,
        safe_cards_played: 0,
        kaos_cards_played: 0,
        consecutive_kaos_count: 0,
        current_phase_number: 1,
        game_phase: 'discussion',
        cards_in_deck: deck,
        selected_cards: [],
        advisor_cards: [],
        advisor_can_view_role: false,
        advisor_can_investigate: false,
        card_peeker_player_id: null,
        viewed_player_id: null,
        last_advisor_id: null,
        phase_end_time: getPhaseEndTime(60),
      })

    await chatPanelRef.value?.sendSystemMessage('🎮 Oyun başladı! Roller dağıtıldı.')
    await chatPanelRef.value?.sendSystemMessage('💬 Tartışma başladı! Kimin Yetkili olmasını istiyorsunuz?')

    await fetchData()
  } catch (error) {
    console.error('Error starting game:', error)
  } finally {
    loading.value = false
  }
}

const startVotingPhase = async () => {
  if (!gameState.value || !room.value) return
  if (!isHost.value) return

  votingPurpose.value = 'authority'

  const ok = await updateGameState(
    {
      game_phase: 'voting',
      phase_end_time: getPhaseEndTime(45),
    },
    'startVotingPhase',
    'discussion'
  )
  if (!ok) return

  await chatPanelRef.value?.sendSystemMessage('🗳️ Oylama başladı! Yetkili için oy verin.')
}

const skipDiscussion = async () => {
  if (!isHost.value) return
  if (gameState.value?.game_phase !== 'discussion') return
  await startVotingPhase()
  await chatPanelRef.value?.sendSystemMessage('⏭️ Tartışma atlandı! Oylama başladı.')
}

const finishVotingPhase = async () => {
  if (gameState.value?.game_phase !== 'voting') return
  if (!isHost.value) return
  if (!beginPhaseAdvance()) return
  try {
    if (isRolePeekVoteMode.value) {
      await countVotesAndSelectRolePeeker()
    } else if (isKillVoteMode.value) {
      await countVotesAndSelectKillVoter()
    } else {
      await countVotesAndSelectAuthority()
    }
  } catch (error) {
    console.error('Error finishing voting phase:', error)
  } finally {
    endPhaseAdvance()
  }
}

const advanceFromReveal = async (force = false) => {
  if (!gameState.value) return
  if (!isHost.value) return
  if (!force && gameState.value.game_phase !== 'reveal') return
  if (!force && !isPhaseExpired() && !isRevealStuck()) return
  if (!beginPhaseAdvance()) return
  try {
    const safeCount = gameState.value.safe_cards_played
    const kaosCount = gameState.value.kaos_cards_played
    const target = winTarget.value

    if (safeCount >= target) {
      await endGame('sadik')
    } else if (kaosCount >= target) {
      await endGame('hain')
    } else {
      await nextTurn('reveal', force)
    }
  } catch (error) {
    console.error('Error advancing from reveal:', error)
    showDbToast('Kart açılışından tur ilerletilemedi', error as { message?: string })
  } finally {
    endPhaseAdvance()
  }
}

const castVote = async () => {
  if (!selectedVotePlayerId.value || !gameState.value || !room.value || hasVoted.value) return

  if (!currentPlayer.value?.is_alive) {
    return
  }

  try {
    await supabase
      .from('votes')
      .insert({
        room_id: room.value.id,
        turn_number: gameState.value.current_turn,
        voter_player_id: currentPlayerId.value,
        voted_for_player_id: selectedVotePlayerId.value,
      })

    const votedPlayer = players.value.find(p => p.id === selectedVotePlayerId.value)
    await chatPanelRef.value?.sendSystemMessage(
      `${playerName(currentPlayer.value?.name)}, ${playerName(votedPlayer?.name)} için oy kullandı.`
    )

    selectedVotePlayerId.value = null
    await fetchVotes()
  } catch (error) {
    console.error('Error casting vote:', error)
  }
}

const countVotesAndSelectAuthority = async () => {
  if (!gameState.value || !room.value) return

  const currentTurnVotes = votes.value.filter(v => v.turn_number === gameState.value?.current_turn)
  const alivePlayers = players.value.filter(p => p.is_alive)

  if (alivePlayers.length === 0) return

  const voteCounts: Record<string, number> = {}
  currentTurnVotes.forEach(vote => {
    if (vote.voted_for_player_id) {
      const votedPlayer = alivePlayers.find(p => p.id === vote.voted_for_player_id)
      if (votedPlayer) {
        voteCounts[vote.voted_for_player_id] = (voteCounts[vote.voted_for_player_id] || 0) + 1
      }
    }
  })

  const sorted = Object.entries(voteCounts).sort((a, b) => b[1] - a[1])

  let authorityId = sorted[0]?.[0]
  let advisorId = sorted[1]?.[0]

  if (!authorityId) {
    const randomIndex = Math.floor(Math.random() * alivePlayers.length)
    authorityId = alivePlayers[randomIndex].id
    const nextIndex = (randomIndex + 1) % alivePlayers.length
    advisorId = alivePlayers[nextIndex].id
  }

  if (!advisorId) {
    const authorityIndex = alivePlayers.findIndex(p => p.id === authorityId)
    const nextIndex = (authorityIndex + 1) % alivePlayers.length
    advisorId = alivePlayers[nextIndex].id
  }

  if (advisorId === gameState.value.last_advisor_id) {
    const advisorIndex = alivePlayers.findIndex(p => p.id === advisorId)
    let nextIndex = (advisorIndex + 1) % alivePlayers.length
    advisorId = alivePlayers[nextIndex].id

    if (advisorId === authorityId && alivePlayers.length > 2) {
      nextIndex = (nextIndex + 1) % alivePlayers.length
      advisorId = alivePlayers[nextIndex].id
    }
  }

  const authorityPlayer = players.value.find(p => p.id === authorityId)
  const advisorPlayer = players.value.find(p => p.id === advisorId)

  if (gameState.value.kaos_cards_played >= 3 && authorityPlayer?.role === 'ajan') {
    await chatPanelRef.value?.sendSystemMessage(
      `🎭 3. Kaos kartından sonra ${playerName(authorityPlayer?.name)} Özel Ajan olarak Yetkili seçildi! Hainler kazandı!`
    )
    await endGame('hain')
    return
  }

  const ok = await updateGameState(
    {
      current_authority_player_id: authorityId,
      current_advisor_player_id: advisorId,
      last_advisor_id: advisorId,
      game_phase: 'authority_selection',
      phase_end_time: getPhaseEndTime(30),
    },
    'countVotesAndSelectAuthority',
    'voting'
  )
  if (!ok) return

  await chatPanelRef.value?.sendSystemMessage(
    `⚖️ Oylamalar tamamlandı! ${playerName(authorityPlayer?.name, 'Yetkili')} Yetkili, ${playerName(advisorPlayer?.name, 'Danışan')} Danışan seçildi!`
  )

  await drawCards()
}

const drawCards = async () => {
  if (!gameState.value || !room.value) return

  let deck = [...gameState.value.cards_in_deck]

  if (deck.length < 3) {
    const newDeck = generateDeck()
    deck = [...deck, ...newDeck]
    await chatPanelRef.value?.sendSystemMessage(
      `🔄 Kartlar bitti! Yeni kartlar karıştırılıp eklendi.`
    )
  }

  const drawnCards = deck.splice(0, 3)

  await supabase
    .from('game_states')
    .update({
      cards_in_deck: deck,
      selected_cards: drawnCards,
    })
    .eq('room_id', room.value.id)

  await chatPanelRef.value?.sendSystemMessage(
    `📋 ${playerName(currentAuthorityPlayer.value?.name, 'Yetkili')} 3 kart çekti!`
  )
}

const selectAuthorityCardAtIndex = async (cardIndex: number) => {
  if (!gameState.value || !room.value || gameState.value.game_phase !== 'authority_selection') return
  if (cardIndex < 0 || cardIndex >= gameState.value.selected_cards.length) return

  const buriedCard = gameState.value.selected_cards[cardIndex]
  const cards = [...gameState.value.selected_cards]
  cards.splice(cardIndex, 1)

  const ok = await updateGameState(
    {
      advisor_cards: cards,
      selected_cards: [],
      game_phase: 'advisor_selection',
      phase_end_time: getPhaseEndTime(30),
    },
    'selectAuthorityCardAtIndex',
    'authority_selection'
  )
  if (!ok) return

  await supabase
    .from('game_actions')
    .insert({
      room_id: room.value.id,
      turn_number: gameState.value.current_turn,
      action_type: 'card_played',
      player_id: gameState.value.current_authority_player_id ?? currentPlayerId.value,
      data: { buried_card: buriedCard, buried_by: 'authority' },
    })

  await chatPanelRef.value?.sendSystemMessage(
    `📋 ${playerName(currentAuthorityPlayer.value?.name, 'Yetkili')} bir kartı gömüp 2 kartı ${playerName(currentAdvisorPlayer.value?.name, 'Danışan')}'a verdi!`
  )

  selectedCardIndex.value = null
}

const selectAuthorityCard = async () => {
  if (!isCurrentAuthority.value || selectedCardIndex.value === null) return
  await selectAuthorityCardAtIndex(selectedCardIndex.value)
}

const selectAdvisorCardAtIndex = async (cardIndex: number) => {
  if (!gameState.value || !room.value || gameState.value.game_phase !== 'advisor_selection') return
  if (cardIndex < 0 || cardIndex >= gameState.value.advisor_cards.length) return

  const buriedCard = gameState.value.advisor_cards[cardIndex]
  const revealedCard = gameState.value.advisor_cards.find((_, i) => i !== cardIndex)!

  const newSafeCount = revealedCard === 'safe'
    ? gameState.value.safe_cards_played + 1
    : gameState.value.safe_cards_played

  const newKaosCount = revealedCard === 'kaos'
    ? gameState.value.kaos_cards_played + 1
    : gameState.value.kaos_cards_played

  const newConsecutiveKaos = revealedCard === 'kaos'
    ? gameState.value.consecutive_kaos_count + 1
    : 0

  const newPhaseNumber = revealedCard === 'safe'
    ? gameState.value.current_phase_number + 1
    : gameState.value.current_phase_number

  const isSecondKaosCard = revealedCard === 'kaos' && newKaosCount === 2
  const isThirdKaosCard = revealedCard === 'kaos' && newKaosCount === 3

  await supabase
    .from('game_actions')
    .insert({
      room_id: room.value.id,
      turn_number: gameState.value.current_turn,
      action_type: 'card_played',
      player_id: currentAdvisorPlayer.value?.id,
      data: { card_type: revealedCard, buried_card: buriedCard },
    })

  await chatPanelRef.value?.sendSystemMessage(
    `${playerName(currentAdvisorPlayer.value?.name, 'Danışan')} bir ${revealedCard === 'safe' ? 'Safe' : 'Kaos'} kartı açtı!`
  )

  if (isThirdKaosCard) {
    const target = winTarget.value
    if (newSafeCount >= target) {
      await endGame('sadik')
      return
    }
    if (newKaosCount >= target) {
      await endGame('hain')
      return
    }

    if (!gameState.value.current_authority_player_id) {
      showDbToast('Yetkili atanmadı — önce tur oylamasını tamamlayın', null, 'warning')
      return
    }

    const ok3 = await updateGameState(
      {
        advisor_cards: [],
        game_phase: 'authority_kill',
        phase_end_time: getPhaseEndTime(15),
        safe_cards_played: newSafeCount,
        kaos_cards_played: newKaosCount,
        consecutive_kaos_count: newConsecutiveKaos,
        current_phase_number: newPhaseNumber,
        advisor_can_view_role: false,
        advisor_can_investigate: true,
        card_peeker_player_id: null,
        viewed_player_id: null,
      },
      'selectAdvisorCard thirdKaos',
      'advisor_selection'
    )
    if (!ok3) return

    await chatPanelRef.value?.sendSystemMessage(
      `⚔️ 3. Kaos kartı açıldı! Yetkili ${playerName(currentAuthorityPlayer.value?.name)} 15 saniye içinde bir oyuncuyu oyun dışı bırakabilir.`
    )
  } else if (isSecondKaosCard) {
    const target = winTarget.value
    if (newSafeCount >= target) {
      await endGame('sadik')
      return
    }
    if (newKaosCount >= target) {
      await endGame('hain')
      return
    }

    if (!gameState.value.current_authority_player_id) {
      showDbToast('Yetkili atanmadı — önce tur oylamasını tamamlayın', null, 'warning')
      return
    }

    const ok2 = await updateGameState(
      {
        advisor_cards: [],
        game_phase: 'authority_view_role',
        phase_end_time: getPhaseEndTime(15),
        safe_cards_played: newSafeCount,
        kaos_cards_played: newKaosCount,
        consecutive_kaos_count: newConsecutiveKaos,
        current_phase_number: newPhaseNumber,
        advisor_can_view_role: true,
        advisor_can_investigate: false,
        card_peeker_player_id: null,
        viewed_player_id: null,
      },
      'selectAdvisorCard secondKaos',
      'advisor_selection'
    )
    if (!ok2) return

    peekedRole.value = null
    await chatPanelRef.value?.sendSystemMessage(
      `🔍 2. Kaos kartı açıldı! Yetkili ${playerName(currentAuthorityPlayer.value?.name)} 15 saniye içinde bir oyuncunun rolünü gizlice görebilir.`
    )
  } else {
    const okReveal = await updateGameState(
      {
        advisor_cards: [],
        game_phase: 'reveal',
        phase_end_time: getPhaseEndTime(5),
        safe_cards_played: newSafeCount,
        kaos_cards_played: newKaosCount,
        consecutive_kaos_count: newConsecutiveKaos,
        current_phase_number: newPhaseNumber,
        advisor_can_view_role: false,
        advisor_can_investigate: false,
      },
      'selectAdvisorCard reveal',
      'advisor_selection'
    )
    if (!okReveal) return
  }

  selectedCardIndex.value = null
}

const selectAdvisorCard = async () => {
  if (!isCurrentAdvisor.value || selectedCardIndex.value === null) return
  await selectAdvisorCardAtIndex(selectedCardIndex.value)
}

const peekedRole = ref<{ playerName: string; role: string } | null>(null)

const getRoleLabel = (role?: string) => {
  switch (role) {
    case 'sadik': return 'Sadık'
    case 'hain': return 'Hain'
    case 'ajan': return 'Özel Ajan'
    default: return 'Bilinmiyor'
  }
}

const roleForPrivatePeek = (role?: string) => {
  if (role === 'ajan') return 'hain'
  return role ?? 'unknown'
}

const pickVoteWinner = (alivePlayers: Player[]) => {
  const currentTurnVotes = votes.value.filter(v => v.turn_number === gameState.value?.current_turn)
  const voteCounts: Record<string, number> = {}
  currentTurnVotes.forEach(vote => {
    if (vote.voted_for_player_id) {
      const votedPlayer = alivePlayers.find(p => p.id === vote.voted_for_player_id)
      if (votedPlayer) {
        voteCounts[vote.voted_for_player_id] = (voteCounts[vote.voted_for_player_id] || 0) + 1
      }
    }
  })
  const sorted = Object.entries(voteCounts).sort((a, b) => b[1] - a[1])
  let winnerId = sorted[0]?.[0]
  if (!winnerId) {
    const randomIndex = Math.floor(Math.random() * alivePlayers.length)
    winnerId = alivePlayers[randomIndex].id
  }
  return winnerId
}

const countVotesAndSelectRolePeeker = async () => {
  if (!gameState.value || !room.value) return

  const alivePlayers = players.value.filter(p => p.is_alive)
  if (alivePlayers.length === 0) return

  const peekerId = pickVoteWinner(alivePlayers)
  const peekerPlayer = players.value.find(p => p.id === peekerId)

  const ok = await updateGameState(
    {
      card_peeker_player_id: peekerId,
      game_phase: 'role_peek',
      phase_end_time: getPhaseEndTime(25),
      advisor_can_view_role: false,
      advisor_can_investigate: false,
    },
    'countVotesAndSelectRolePeeker',
    'voting'
  )
  if (!ok) return

  votingPurpose.value = 'authority'

  await chatPanelRef.value?.sendSystemMessage(
    `🔍 ${playerName(peekerPlayer?.name)} seçildi! Bir oyuncunun rolünü gizlice görebilir (sadece kendisi görür).`
  )

  peekedRole.value = null
}

const peekPlayerRole = async (targetPlayer: Player) => {
  if (!gameState.value || rolePeekUsed.value || gameState.value.viewed_player_id) return

  const revealRole = () => {
    rolePeekUsed.value = true
    peekedRole.value = {
      playerName: targetPlayer.name,
      role: roleForPrivatePeek(targetPlayer.role),
    }
  }

  if (gameState.value.game_phase === 'authority_view_role') {
    if (!isCurrentAuthority.value) return
    if (room.value) {
      await updateGameState(
        { viewed_player_id: targetPlayer.id },
        'peekPlayerRole authority',
        'authority_view_role'
      )
    }
    revealRole()
    return
  }

  if (
    gameState.value.card_peeker_player_id === currentPlayerId.value &&
    (gameState.value.game_phase === 'role_peek' || gameState.value.game_phase === 'card_peek')
  ) {
    if (room.value) {
      await updateGameState(
        { viewed_player_id: targetPlayer.id },
        'peekPlayerRole legacy',
        gameState.value.game_phase
      )
    }
    revealRole()
  }
}

const finishAuthorityRoleView = async () => {
  if (!gameState.value || gameState.value.game_phase !== 'authority_view_role') return
  peekedRole.value = null
  await chatPanelRef.value?.sendSystemMessage(
    'Rol görüntüleme bitti. Yeni tur başlıyor.'
  )
  await nextTurn('authority_view_role')
}

const finishRolePeek = async () => {
  if (!gameState.value || !room.value) return
  peekedRole.value = null

  const { error: voteDelError } = await supabase
    .from('votes')
    .delete()
    .eq('room_id', room.value.id)
    .eq('turn_number', gameState.value.current_turn)
  if (voteDelError) logDbError('finishRolePeek delete votes', voteDelError)

  votes.value = []

  const ok = await updateGameState(
    {
      game_phase: 'voting',
      phase_end_time: getPhaseEndTime(45),
      card_peeker_player_id: null,
      advisor_can_view_role: false,
      advisor_can_investigate: false,
    },
    'finishRolePeek',
    'role_peek'
  )
  votingPurpose.value = 'authority'

  if (!ok) {
    const okCardPeek = await updateGameState(
      {
        game_phase: 'voting',
        phase_end_time: getPhaseEndTime(45),
        card_peeker_player_id: null,
        advisor_can_view_role: false,
        advisor_can_investigate: false,
      },
      'finishRolePeek card_peek',
      'card_peek'
    )
    if (!okCardPeek) return
  }

  await chatPanelRef.value?.sendSystemMessage(
    '🗳️ Rol görüntüleme bitti! Yetkili ve Danışman için oylama başladı. (Özel Ajan Yetkili olursa Hainler kazanır)'
  )
}

const countVotesAndSelectKillVoter = async () => {
  if (!gameState.value || !room.value) return

  const alivePlayers = players.value.filter(p => p.is_alive)
  if (alivePlayers.length === 0) return

  const killerId = pickVoteWinner(alivePlayers)
  const killerPlayer = players.value.find(p => p.id === killerId)

  const ok = await updateGameState(
    {
      card_peeker_player_id: killerId,
      game_phase: 'player_kill',
      phase_end_time: getPhaseEndTime(20),
      advisor_can_investigate: false,
      advisor_can_view_role: false,
    },
    'countVotesAndSelectKillVoter',
    'voting'
  )
  if (!ok) return

  await chatPanelRef.value?.sendSystemMessage(
    `⚔️ ${playerName(killerPlayer?.name)} öldürme gücü kazandı! Bir oyuncuyu eleyebilir.`
  )
}

const eliminatePlayer = async (targetPlayer: Player, killerName: string) => {
  if (!gameState.value || !room.value) return
  if (killUsed.value) return
  killUsed.value = true

  await supabase
    .from('players')
    .update({ is_alive: false })
    .eq('id', targetPlayer.id)

  await chatPanelRef.value?.sendSystemMessage(
    `${playerName(killerName)} ${playerName(targetPlayer.name)} oyuncusunu oyun dışı bıraktı!`
  )

  if (targetPlayer.role === 'ajan') {
    await chatPanelRef.value?.sendSystemMessage('Özel Ajan elendi! Sadıklar kazandı!')
    await endGame('sadik')
    return
  }

  await fetchData()
  const aliveHainTeam = players.value.filter(p => p.is_alive && (p.role === 'hain' || p.role === 'ajan'))
  if (aliveHainTeam.length === 0) {
    await chatPanelRef.value?.sendSystemMessage('Tüm Hain takımı elendi! Sadıklar kazandı!')
    await endGame('sadik')
    return
  }

  const advanceFrom =
    gameState.value?.game_phase === 'authority_kill' ? 'authority_kill' : 'player_kill'
  await nextTurn(advanceFrom)
}

const killPlayerByAuthority = async (targetPlayer: Player) => {
  if (!canAuthorityKill.value || !gameState.value || !room.value) return
  if (killUsed.value) return
  await eliminatePlayer(
    targetPlayer,
    playerName(currentAuthorityPlayer.value?.name, 'Yetkili')
  )
}

const skipAuthorityKill = async (forced = false) => {
  if (!gameState.value || !room.value) return
  if (gameState.value.game_phase !== 'authority_kill') return
  if (!forced && !isCurrentAuthority.value) return
  await chatPanelRef.value?.sendSystemMessage(
    `${playerName(currentAuthorityPlayer.value?.name, 'Yetkili')} kimseyi elemedi.`
  )
  await nextTurn('authority_kill')
}

const killPlayerByVoter = async (targetPlayer: Player) => {
  if (!isKillVoter.value || !gameState.value || !room.value) return
  if (gameState.value.game_phase !== 'player_kill') return
  if (killUsed.value) return

  const killer = killVoterPlayer.value
  await eliminatePlayer(targetPlayer, killer?.name ?? 'Seçilen oyuncu')
}

const skipKillByVoter = async (forced = false) => {
  if (!gameState.value || !room.value) return
  if (gameState.value.game_phase !== 'player_kill') return
  if (!forced && !isKillVoter.value) return
  await chatPanelRef.value?.sendSystemMessage(
    `${playerName(killVoterPlayer.value?.name, 'Seçilen oyuncu')} öldürme gücünü kullanmadı.`
  )
  await nextTurn('player_kill')
}

const nextTurn = async (
  fromPhase: 'reveal' | 'player_kill' | 'authority_view_role' | 'authority_kill' = 'reveal',
  force = false
) => {
  if (!gameState.value || !room.value) return
  if (isProcessingTurn) return
  isProcessingTurn = true

  try {
    await fetchGameStateOnly()
    if (!gameState.value) return

    const expectedTurn = gameState.value.current_turn
    const nextTurnNumber = expectedTurn + 1

    if (force) {
      if (isTurnAlreadyAdvanced(nextTurnNumber)) return
      if (gameState.value.game_phase === 'discussion') return
      if (gameState.value.game_phase !== fromPhase) return
    } else if (gameState.value.game_phase !== fromPhase) {
      if (isTurnAlreadyAdvanced(nextTurnNumber)) return
      return
    }

    votingPurpose.value = 'authority'

    const corePatch: Record<string, unknown> = {
      current_turn: nextTurnNumber,
      current_authority_player_id: null,
      current_advisor_player_id: null,
      game_phase: 'discussion',
      phase_end_time: getPhaseEndTime(60),
      consecutive_kaos_count:
        fromPhase === 'authority_kill' || fromPhase === 'player_kill'
          ? 0
          : gameState.value.consecutive_kaos_count,
      selected_cards: [],
      advisor_cards: [],
    }

    const fullPatch: Record<string, unknown> = {
      ...corePatch,
      advisor_can_view_role: false,
      advisor_can_investigate: false,
      viewed_player_id: null,
      card_peeker_player_id: null,
    }

    const runNextTurnUpdate = async (patch: Record<string, unknown>) =>
      supabase
        .from('game_states')
        .update(patch)
        .eq('room_id', room.value!.id)
        .eq('current_turn', expectedTurn)
        .eq('game_phase', fromPhase)
        .select('id')

    let attemptPatch = { ...fullPatch }
    let { data, error } = await runNextTurnUpdate(attemptPatch)

    let columnRetries = 0
    while (error && isMissingColumnError(error) && columnRetries < 6) {
      const slim = stripMissingColumnFromPatch(attemptPatch, error)
      if (JSON.stringify(slim) === JSON.stringify(attemptPatch)) break
      attemptPatch = slim
      columnRetries += 1
      ;({ data, error } = await runNextTurnUpdate(attemptPatch))
    }

    if (error) {
      const { data: coreData, error: coreError } = await runNextTurnUpdate(corePatch)
      data = coreData
      error = coreError
    }

    if (error) {
      showDbToast(`Tur ${nextTurnNumber} başlatılamadı — Supabase SQL dosyasını çalıştırın`, error)
      return
    }

    if (!data || data.length === 0) {
      await fetchGameStateOnly()
      if (isTurnAlreadyAdvanced(nextTurnNumber)) return
      return
    }

    await chatPanelRef.value?.sendSystemMessage(
      `Yeni tur başladı! Tur ${nextTurnNumber}`
    )

    await fetchData()
  } finally {
    isProcessingTurn = false
  }
}

const syncPhaseIfExpired = async () => {
  if (!gameState.value || room.value?.status !== 'playing') return
  if (!isHost.value) return

  const expired = isPhaseExpired()
  const revealStuck = isRevealStuck()

  if (!expired && !revealStuck) return

  if (phaseAdvanceInFlight) {
    if (Date.now() - phaseAdvanceStartedAt < PHASE_ADVANCE_MAX_MS) return
    endPhaseAdvance()
  }

  if (revealStuck && gameState.value.game_phase === 'reveal') {
    await advanceFromReveal(true)
    return
  }

  await handlePhaseTimeout()
}

const handlePhaseTimeout = async () => {
  if (!gameState.value || !room.value) return
  if (!isHost.value) return
  const phase = gameState.value.game_phase

  if (phase === 'voting') {
    await finishVotingPhase()
    return
  }

  if (phase === 'reveal') {
    await advanceFromReveal(isRevealStuck())
    return
  }

  if (!beginPhaseAdvance()) return

  try {
    if (phase === 'discussion') {
      await startVotingPhase()

    } else if (phase === 'authority_selection') {
      if (gameState.value.selected_cards.length === 3) {
        const randomIndex = Math.floor(Math.random() * 3)
        await selectAuthorityCardAtIndex(randomIndex)
      }

    } else if (phase === 'advisor_selection') {
      if (gameState.value.advisor_cards.length === 2) {
        const randomIndex = Math.floor(Math.random() * 2)
        await selectAdvisorCardAtIndex(randomIndex)
      }

    } else if (phase === 'authority_view_role') {
      await finishAuthorityRoleView()

    } else if (phase === 'authority_kill') {
      await skipAuthorityKill(true)

    } else if (phase === 'role_peek' || phase === 'card_peek') {
      await finishRolePeek()

    } else if (phase === 'player_kill') {
      await skipKillByVoter(true)
    }
  } catch (error) {
    console.error('Error handling phase timeout:', error)
  } finally {
    endPhaseAdvance()
  }
}

const endGame = async (winner: 'sadik' | 'hain') => {
  if (!room.value) return

  await supabase
    .from('rooms')
    .update({
      status: 'finished',
      winning_team: winner,
      finished_at: new Date().toISOString(),
    })
    .eq('id', room.value.id)

  await chatPanelRef.value?.sendSystemMessage(
    winner === 'sadik' ? '🏆 Sadıklar kazandı!' : '🏆 Hainler kazandı!'
  )

  await fetchData()
}

const leaveRoom = async () => {
  if (!currentPlayerId.value) return

  if (room.value?.status !== 'playing') {
    await supabase
      .from('players')
      .delete()
      .eq('id', currentPlayerId.value)
  }

  sessionStorage.removeItem('playerId')
  router.push('/')
}

/** Oyun bittiğinde ana sayfaya dön — yeni oda kurma / katılma */
const goCreateNewRoom = async () => {
  if (currentPlayerId.value) {
    await supabase
      .from('players')
      .delete()
      .eq('id', currentPlayerId.value)
    sessionStorage.removeItem('playerId')
  }
  router.push('/')
}

const fetchVotes = async () => {
  if (!room.value || !gameState.value) return

  const { data } = await supabase
    .from('votes')
    .select('*')
    .eq('room_id', room.value.id)
    .eq('turn_number', gameState.value.current_turn)

  votes.value = data || []
}

const fetchData = async () => {
  if (!supabaseEnabled) {
    loading.value = false
    snackbar.value = {
      show: true,
      color: 'warning',
      text: 'Supabase ayarlı değil. Online oyun için .env ayarlarını yapın.',
    }
    return
  }
  try {
    const { data: roomData, error: roomError } = await supabase
      .from('rooms')
      .select('*')
      .eq('room_code', roomCode)
      .maybeSingle()

    if (roomError || !roomData) {
      console.error('Room not found')
      router.push('/')
      return
    }

    room.value = roomData
    markSupabaseConnected()

    const { data: playersData } = await supabase
      .from('players')
      .select('*')
      .eq('room_id', roomData.id)
      .order('joined_at', { ascending: true })

    players.value = playersData || []

    const savedPlayerId = sessionStorage.getItem('playerId')
    const savedPlayerName = sessionStorage.getItem('playerName')?.trim()
    let player = players.value.find(p => p.id === savedPlayerId)

    if (!player && savedPlayerName && roomData.status !== 'waiting') {
      player = players.value.find(
        p => p.name.trim().toLocaleLowerCase('tr-TR') === savedPlayerName.toLocaleLowerCase('tr-TR')
      )
      if (player) sessionStorage.setItem('playerId', player.id)
    }

    if (!player) {
      currentPlayerId.value = ''
    } else {
      currentPlayerId.value = player.id
    }

    if (roomData.status === 'playing' || roomData.status === 'finished') {
      const { data: stateData } = await supabase
        .from('game_states')
        .select('*')
        .eq('room_id', roomData.id)
        .maybeSingle()

      if (stateData) {
        gameState.value = normalizeGameState(stateData as Record<string, unknown>)
        syncVotingPurposeFromState(gameState.value)

        if (roomData.status === 'playing') {
          await fetchVotes()
        }
      }
    }
  } catch (error) {
    console.error('Error fetching data:', error)
  } finally {
    loading.value = false
  }
}

const refreshGameStateSafe = async () => {
  const now = Date.now()

  if (isRefreshingGameState) return
  if (now - lastGameStateUpdate < 300) return

  isRefreshingGameState = true
  isRealtimeRefreshTick = true
  lastGameStateUpdate = now

  try {
    await fetchData()
  } finally {
    isRefreshingGameState = false
    window.setTimeout(() => {
      isRealtimeRefreshTick = false
    }, 0)
  }
}

const onRealtimeUiChange = () => {
  // Realtime events must only refresh UI state. Phase writes still run from timers,
  // host controls, and explicit user actions, never from this callback.
  void refreshGameStateSafe()
}

const initRealtimeChannels = () => {
  if (!supabaseEnabled) return
  if (playersChannel || roomChannel || gameStateChannel || votesChannel) return
  if (!room.value?.id) return

  const roomId = room.value.id

  playersChannel = supabase
    .channel(`room:${roomCode}:players`)
    .on(
      'postgres_changes',
      {
        event: '*',
        schema: 'public',
        table: 'players',
        filter: `room_id=eq.${roomId}`,
      },
      onRealtimeUiChange
    )
    .subscribe((status: string) => {
      console.log('Players channel status:', status)
    })

  roomChannel = supabase
    .channel(`room:${roomCode}:room`)
    .on(
      'postgres_changes',
      {
        event: '*',
        schema: 'public',
        table: 'rooms',
        filter: `room_code=eq.${roomCode}`,
      },
      onRealtimeUiChange
    )
    .subscribe((status: string) => {
      console.log('Room channel status:', status)
    })

  gameStateChannel = supabase
    .channel(`room:${roomCode}:game_states`)
    .on(
      'postgres_changes',
      {
        event: '*',
        schema: 'public',
        table: 'game_states',
        filter: `room_id=eq.${roomId}`,
      },
      onRealtimeUiChange
    )
    .subscribe((status: string) => {
      console.log('Game state channel status:', status)
    })

  votesChannel = supabase
    .channel(`room:${roomCode}:votes`)
    .on(
      'postgres_changes',
      {
        event: '*',
        schema: 'public',
        table: 'votes',
        filter: `room_id=eq.${roomId}`,
      },
      onRealtimeUiChange
    )
    .subscribe((status: string) => {
      console.log('Votes channel status:', status)
    })
}

onMounted(async () => {
  await fetchData()

  if (!supabaseEnabled) {
    // Supabase yokken realtime/polling başlatma
    return
  }

  phaseSyncInterval = setInterval(() => {
    if (room.value?.status === 'playing') {
      void syncPhaseIfExpired()
    }
  }, 2000)

  initRealtimeChannels()
})

watch(allAlivePlayersVoted, async (allVoted) => {
  if (isRefreshingGameState || isRealtimeRefreshTick) return
  if (!allVoted || gameState.value?.game_phase !== 'voting') return
  await finishVotingPhase()
})

watch(
  () => [gameState.value?.game_phase, gameState.value?.phase_end_time] as const,
  ([phase], [previousPhase]) => {
    if (phase !== previousPhase) {
      rolePeekUsed.value = false
      killUsed.value = false
    }
    if (isRefreshingGameState || isRealtimeRefreshTick) return
    syncPhaseIfExpired()
  }
)

watch(
  () => ({
    safe: gameState.value?.safe_cards_played ?? 0,
    kaos: gameState.value?.kaos_cards_played ?? 0,
    status: room.value?.status ?? null,
    winner: room.value?.winning_team ?? null,
  }),
  (current) => {
    const previous = lastSoundState.value

    if (previous.status === null) {
      lastSoundState.value = current
      return
    }

    if (previous.status === 'waiting' && current.status === 'playing') {
      playGameStart()
    }

    if (current.safe > previous.safe) {
      playCardReveal('safe')
    } else if (current.kaos > previous.kaos) {
      playCardReveal('kaos')
    }

    if (previous.status !== 'finished' && current.status === 'finished' && current.winner) {
      playGameEnd(current.winner)
    }

    lastSoundState.value = current
  },
  { deep: false }
)

onUnmounted(() => {
  if (phaseSyncInterval) clearInterval(phaseSyncInterval)
  if (supabaseEnabled) {
    if (playersChannel) {
      supabase.removeChannel(playersChannel)
      playersChannel = null
    }
    if (roomChannel) {
      supabase.removeChannel(roomChannel)
      roomChannel = null
    }
    if (gameStateChannel) {
      supabase.removeChannel(gameStateChannel)
      gameStateChannel = null
    }
    if (votesChannel) {
      supabase.removeChannel(votesChannel)
      votesChannel = null
    }
  }
})
</script>

<template>
  <!-- Loading -->
  <div v-if="loading" class="page-loading">
    <v-progress-circular indeterminate size="64" color="primary" />
  </div>

  <div v-else class="game-page">
    <SetupBanner />

    <div v-if="supabaseBlocked" class="blocked-area">
      <v-alert type="warning" variant="tonal" border="start" class="blocked-card">
        <div class="text-h6 mb-2">Supabase ayarlı değil</div>
        <div class="text-body-2 mb-4">
          Bu oda ekranı online veritabanı olmadan çalışamaz. Lütfen <code>.env</code> dosyanızı ayarlayın ve uygulamayı yeniden başlatın.
        </div>
        <v-btn color="primary" variant="tonal" @click="router.push('/')">
          Ana Sayfaya Dön
        </v-btn>
      </v-alert>
    </div>

    <!-- Header -->
    <div v-else class="game-header">
      <div class="header-left">
        <div class="room-name">{{ room?.name }}</div>
        <div class="room-code">Oda Kodu: {{ roomCode }}</div>
      </div>
      <div v-if="isGamePlaying" class="header-center">
        <div class="turn-badge">Tur {{ gameState?.current_turn }}</div>
      </div>
      <div class="header-right">
        <v-chip
          :color="room?.status === 'waiting' ? 'success' : room?.status === 'playing' ? 'warning' : 'error'"
          size="large"
        >
          {{ room?.status === 'waiting' ? 'Bekliyor' : room?.status === 'playing' ? 'Oyunda' : 'Bitti' }}
        </v-chip>
      </div>
    </div>

    <!-- Waiting -->
    <div v-if="!supabaseBlocked && isGameWaiting" class="waiting-area">
      <div class="waiting-card">
        <v-icon size="72" color="primary" class="mb-4">mdi-timer-sand</v-icon>
        <div class="text-h5 mb-2">Oyun başlamayı bekliyor...</div>
        <div class="text-subtitle-1 mb-6 text-medium-emphasis">
          {{ players.length }} / {{ room?.max_players }} oyuncu
        </div>
        <v-btn v-if="canStartGame" color="success" size="x-large" @click="startGame">
          Oyunu Başlat
        </v-btn>
        <v-alert v-else-if="isHost" type="info" variant="tonal" class="mt-4" max-width="400">
          Oyunu başlatmak için en az 5 oyuncu gerekli
        </v-alert>

        <div class="players-waiting mt-8">
          <div class="text-h6 mb-3">Odadaki Oyuncular</div>
          <div class="player-chips">
            <v-chip
              v-for="p in players"
              :key="p.id"
              :color="p.id === currentPlayerId ? 'primary' : 'default'"
              size="large"
              class="ma-1"
            >
              <v-icon start>{{ p.is_host ? 'mdi-crown' : 'mdi-account' }}</v-icon>
              {{ p.name }}
            </v-chip>
          </div>
        </div>
      </div>
    </div>

    <!-- Game playing or finished -->
    <div v-else-if="!supabaseBlocked" class="game-area" :class="{ 'game-area--finished': isGameFinished }">
      <!-- Left: Game Board -->
      <div class="game-board">
        <!-- Zone: HUD (timer + scores while playing) -->
        <section v-if="isGamePlaying" class="board-zone board-zone--hud">
          <PhaseTimer
            v-if="gameState?.phase_end_time"
            :end-time="gameState.phase_end_time"
            :phase="gameState.game_phase"
            @timeout="handlePhaseTimeout"
          />
          <div class="score-row">
            <div class="score-card score-sadik score-card--pulse">
              <v-icon size="28">mdi-shield-check</v-icon>
              <div class="score-number">{{ gameState?.safe_cards_played ?? 0 }}</div>
              <div class="score-label">Sadıklar <span class="score-target">/ {{ winTarget }}</span></div>
            </div>
            <div class="score-card score-hain score-card--pulse">
              <v-icon size="28">mdi-skull</v-icon>
              <div class="score-number">{{ gameState?.kaos_cards_played ?? 0 }}</div>
              <div class="score-label">Hainler <span class="score-target">/ {{ winTarget }}</span></div>
            </div>
          </div>
        </section>

        <!-- Zone: status (game over) -->
        <section v-if="isGameFinished" class="board-zone board-zone--status">
          <div class="game-over-panel">
            <v-alert
              v-if="winnerBanner"
              :color="winnerBanner.color"
              variant="tonal"
              prominent
              class="winner-banner"
            >
              <div class="winner-banner-title">{{ winnerBanner.title }}</div>
              <div class="winner-banner-subtitle">{{ winnerBanner.subtitle }}</div>
            </v-alert>
            <v-alert v-else type="info" variant="tonal" prominent class="winner-banner">
              <div class="winner-banner-title">Oyun bitti</div>
            </v-alert>
            <v-btn
              color="success"
              size="x-large"
              block
              class="new-room-btn"
              prepend-icon="mdi-plus-circle"
              @click="goCreateNewRoom"
            >
              Oda Kur
            </v-btn>
            <p class="game-over-hint">Ana sayfadan yeni bir oda oluşturabilir veya mevcut bir odaya katılabilirsiniz.</p>
          </div>
        </section>

        <!-- Zone: scores (finished only) -->
        <section v-if="isGameFinished" class="board-zone board-zone--scores">
          <div class="score-row">
            <div class="score-card score-sadik">
              <v-icon size="28">mdi-shield-check</v-icon>
              <div class="score-number">{{ gameState?.safe_cards_played ?? 0 }}</div>
              <div class="score-label">Sadıklar <span class="score-target">/ {{ winTarget }}</span></div>
            </div>
            <div class="score-card score-hain">
              <v-icon size="28">mdi-skull</v-icon>
              <div class="score-number">{{ gameState?.kaos_cards_played ?? 0 }}</div>
              <div class="score-label">Hainler <span class="score-target">/ {{ winTarget }}</span></div>
            </div>
          </div>
        </section>

        <!-- Zone: active roles (playing only) -->
        <section
          v-if="isGamePlaying && currentAuthorityPlayer && currentAdvisorPlayer"
          class="board-zone board-zone--roles"
        >
          <div class="roles-banner">
            <div class="role-badge role-authority">
              <v-icon size="18">mdi-gavel</v-icon>
              <span>Yetkili: <strong>{{ currentAuthorityPlayer.name }}</strong></span>
            </div>
            <div class="role-badge role-advisor">
              <v-icon size="18">mdi-account-tie</v-icon>
              <span>Danışan: <strong>{{ currentAdvisorPlayer.name }}</strong></span>
            </div>
          </div>
        </section>

        <!-- Gizli rol (sadece seçilen kişi görür — sunucuya yazılmaz) -->
        <section
          v-if="peekedRole && canAuthorityPeekRole"
          class="board-zone board-zone--private"
        >
        <div class="private-card-reveal">
          <div class="private-card-label">Gizli Rol — sadece sen görüyorsun</div>
          <div class="private-card-player">{{ peekedRole.playerName }}</div>
          <div
            v-if="peekedRole.role !== 'unknown'"
            class="private-card-value"
            :class="peekedRole.role === 'sadik' ? 'card-sadik' : peekedRole.role === 'hain' ? 'card-hain' : 'card-agent'"
          >
            <v-icon size="40">
              {{ peekedRole.role === 'sadik' ? 'mdi-shield-check' : peekedRole.role === 'hain' ? 'mdi-skull' : 'mdi-incognito' }}
            </v-icon>
            <span>{{ getRoleLabel(peekedRole.role) }}</span>
          </div>
        </div>
        </section>

        <!-- Zone: phase actions (playing only) -->
        <section
          v-if="isGamePlaying"
          class="board-zone board-zone--actions phase-actions"
          :class="{ 'phase-actions--voting': gameState?.game_phase === 'voting' }"
        >

          <!-- Discussion -->
          <div v-if="gameState?.game_phase === 'discussion'" class="action-panel">
            <v-alert type="info" variant="tonal" class="mb-4">
              Tartışma zamanı! Kimin Yetkili olmasını istiyorsunuz?
            </v-alert>
            <v-btn v-if="isHost" color="primary" size="large" @click="skipDiscussion">
              <v-icon start>mdi-skip-next</v-icon>
              Oylamaya Geç
            </v-btn>
          </div>

          <!-- Voting -->
          <div v-else-if="gameState?.game_phase === 'voting'" class="action-panel action-panel--voting">
            <div class="vote-phase-title">
              {{
                isRolePeekVoteMode
                  ? 'Rol görebilecek kişi için oy kullanın'
                  : isKillVoteMode
                    ? 'Öldürme gücü için oy kullanın'
                    : 'Yetkili için oy kullanın'
              }}
            </div>
            <v-alert v-if="isRolePeekVoteMode" type="warning" variant="tonal" density="compact" class="vote-alert">
              2. Kaos! Seçilen kişi bir oyuncunun rolünü gizlice görecek.
            </v-alert>
            <v-alert v-else-if="isKillVoteMode" type="error" variant="tonal" density="compact" class="vote-alert">
              3. Kaos! Kazanan bir oyuncuyu eleyebilir.
            </v-alert>

            <template v-if="!currentPlayer?.is_alive">
              <v-alert type="warning" variant="tonal" density="compact" class="vote-alert">
                Oyun dışısınız! Oy kullanamazsınız.
              </v-alert>
            </template>
            <template v-else-if="hasVoted">
              <v-alert type="success" variant="tonal" density="compact" class="vote-alert">
                Oyunuz kaydedildi!
              </v-alert>
            </template>
            <template v-else>
              <div class="vote-grid">
                <button
                  v-for="player in votingCandidates"
                  :key="player.id"
                  type="button"
                  class="vote-option"
                  :class="{ 'vote-option--selected': selectedVotePlayerId === player.id }"
                  @click="selectedVotePlayerId = player.id"
                >
                  <v-icon size="18">mdi-account</v-icon>
                  <span class="vote-option-name">{{ player.name }}</span>
                  <v-icon
                    v-if="selectedVotePlayerId === player.id"
                    size="16"
                    color="primary"
                  >
                    mdi-check-circle
                  </v-icon>
                </button>
              </div>
              <v-btn
                :disabled="!selectedVotePlayerId"
                color="primary"
                size="default"
                class="vote-submit-btn"
                @click="castVote"
              >
                Oy Kullan
              </v-btn>
            </template>

            <div v-if="voteResults.length > 0" class="vote-results">
              <div class="vote-results-title">Anlık Sonuçlar</div>
              <div class="vote-bars">
                <div
                  v-for="result in voteResults"
                  :key="result.player?.id"
                  class="vote-bar-row"
                >
                  <span class="vote-name">{{ result.player?.name }}</span>
                  <div class="vote-bar-wrap">
                    <div
                      class="vote-bar-fill"
                      :style="{ width: `${aliveVoters.length ? (result.votes / aliveVoters.length) * 100 : 0}%` }"
                    />
                  </div>
                  <span class="vote-count">{{ result.votes }}</span>
                </div>
              </div>
            </div>

            <v-btn
              v-if="isHost"
              color="warning"
              variant="tonal"
              size="default"
              class="vote-finish-btn"
              @click="finishVotingPhase"
            >
              <v-icon start>mdi-vote</v-icon>
              Oylamayı Bitir
            </v-btn>
          </div>

          <!-- Authority Card Selection -->
          <div v-else-if="gameState?.game_phase === 'authority_selection' && isCurrentAuthority" class="action-panel">
            <div class="text-h6 mb-3">3 karttan birini seç ve göm:</div>
            <div class="policy-card-grid mb-4">
              <button
                v-for="(card, index) in availableCards"
                :key="index"
                type="button"
                class="policy-card"
                :class="[
                  card === 'safe' ? 'policy-card--safe' : 'policy-card--kaos',
                  selectedCardIndex === index ? 'policy-card--selected' : '',
                ]"
                @click="chooseCardIndex(index)"
              >
                <span class="policy-card-top">{{ index + 1 }}</span>
                <v-icon size="44" class="policy-card-icon">
                  {{ card === 'safe' ? 'mdi-shield-check' : 'mdi-skull-crossbones' }}
                </v-icon>
                <span class="policy-card-title">{{ card === 'safe' ? 'Safe' : 'Kaos' }}</span>
                <span class="policy-card-line" />
              </button>
            </div>
            <v-btn :disabled="selectedCardIndex === null" color="primary" size="large" @click="selectAuthorityCard">
              Kartı Göm ve Danışana Ver
            </v-btn>
          </div>

          <!-- Advisor Card Selection -->
          <div v-else-if="gameState?.game_phase === 'advisor_selection' && isCurrentAdvisor" class="action-panel">
            <div class="text-h6 mb-3">Gömmek istediğin kartı seç:</div>
            <div class="policy-card-grid policy-card-grid--two mb-4">
              <button
                v-for="(card, index) in availableCards"
                :key="index"
                type="button"
                class="policy-card"
                :class="[
                  card === 'safe' ? 'policy-card--safe' : 'policy-card--kaos',
                  selectedCardIndex === index ? 'policy-card--selected' : '',
                ]"
                @click="chooseCardIndex(index)"
              >
                <span class="policy-card-top">{{ index + 1 }}</span>
                <v-icon size="44" class="policy-card-icon">
                  {{ card === 'safe' ? 'mdi-shield-check' : 'mdi-skull-crossbones' }}
                </v-icon>
                <span class="policy-card-title">{{ card === 'safe' ? 'Safe' : 'Kaos' }}</span>
                <span class="policy-card-line" />
              </button>
            </div>
            <v-btn :disabled="selectedCardIndex === null" color="primary" size="large" @click="selectAdvisorCard">
              Seç ve Göm
            </v-btn>
          </div>

          <!-- Reveal: kart açıldı (süre dolunca otomatik ilerler) -->
          <div v-else-if="gameState?.game_phase === 'reveal'" class="action-panel">
            <v-alert type="info" variant="tonal" class="mb-3">
              Kart açıldı! Süre dolunca otomatik olarak sonraki tura geçilir.
            </v-alert>
            <v-btn
              v-if="isHost"
              color="warning"
              variant="tonal"
              size="large"
              prepend-icon="mdi-skip-next"
              @click="advanceFromReveal(true)"
            >
              Sonraki Tura Geç
            </v-btn>
          </div>

          <!-- 2. Kaos: Yetkili rol görür (15 sn) -->
          <div v-else-if="canAuthorityPeekRole" class="action-panel">
            <v-alert type="warning" variant="tonal" class="mb-3">
              <strong>2. Kaos kartı — Yetkilisin!</strong> Bir oyuncunun adına tıkla; rolü 15 saniye boyunca sadece sen görürsün.
            </v-alert>
            <div class="vote-grid mb-3">
              <button
                v-for="p in players.filter(p2 => p2.is_alive && p2.id !== currentPlayerId)"
                :key="p.id"
                type="button"
                class="vote-option"
                :class="{ 'vote-option--disabled': rolePeekUsed || !!gameState?.viewed_player_id }"
                :disabled="rolePeekUsed || !!gameState?.viewed_player_id"
                @click="peekPlayerRole(p)"
              >
                <v-icon size="18">mdi-eye-outline</v-icon>
                <span class="vote-option-name">{{ p.name }}</span>
              </button>
            </div>
            <v-btn color="primary" size="large" @click="finishAuthorityRoleView">
              Devam Et
            </v-btn>
          </div>

          <div v-else-if="isAuthorityRoleViewPhase && !isCurrentAuthority" class="action-panel">
            <v-alert type="warning" variant="tonal">
              Yetkili {{ currentAuthorityPlayer?.name }} 15 saniye içinde bir oyuncunun rolünü gizlice inceliyor...
            </v-alert>
          </div>

          <!-- 3. Kaos: Yetkili öldürür (15 sn) -->
          <div v-else-if="canAuthorityKill" class="action-panel">
            <v-alert type="error" variant="tonal" class="mb-3">
              <strong>3. Kaos kartı — Yetkilisin!</strong> 15 saniye içinde bir oyuncuyu oyun dışı bırak. Özel Ajan elenirse Sadıklar kazanır.
            </v-alert>
            <div class="vote-grid mb-3">
              <button
                v-for="p in players.filter(p2 => p2.is_alive && p2.id !== currentPlayerId)"
                :key="p.id"
                type="button"
                class="vote-option vote-option--danger"
                :class="{ 'vote-option--disabled': killUsed }"
                :disabled="killUsed"
                @click="killPlayerByAuthority(p)"
              >
                <v-icon size="18">mdi-skull</v-icon>
                <span class="vote-option-name">{{ p.name }}</span>
              </button>
            </div>
            <v-btn color="grey" variant="tonal" @click="skipAuthorityKill">
              Kimseyi Eleme
            </v-btn>
          </div>

          <div v-else-if="isAuthorityKillPhase && !isCurrentAuthority" class="action-panel">
            <v-alert type="error" variant="tonal">
              Yetkili {{ currentAuthorityPlayer?.name }} 15 saniye içinde bir oyuncuyu oyun dışı bırakabilir...
            </v-alert>
          </div>

          <!-- Eski oylama kazananı öldürme (yedek) -->
          <div v-else-if="gameState?.game_phase === 'player_kill' && gameState?.card_peeker_player_id === currentPlayerId" class="action-panel">
            <v-alert type="error" variant="tonal" class="mb-3">
              <strong>Öldürme gücü!</strong> Bir oyuncuyu eleyebilir veya atlayabilirsin. Rol kamuya açıklanmaz.
            </v-alert>
            <v-list border rounded class="mb-3">
              <v-list-item
                v-for="p in players.filter(p2 => p2.is_alive && p2.id !== currentPlayerId)"
                :key="p.id"
                rounded
                class="cursor-pointer"
                :disabled="killUsed"
                @click="killPlayerByVoter(p)"
              >
                <template #prepend>
                  <v-avatar color="error" size="36">
                    <v-icon size="20">mdi-account</v-icon>
                  </v-avatar>
                </template>
                <v-list-item-title>{{ p.name }}</v-list-item-title>
                <template #append><v-icon color="error">mdi-skull</v-icon></template>
              </v-list-item>
            </v-list>
            <v-btn color="grey" variant="tonal" @click="skipKillByVoter">Kimseyi Eleme</v-btn>
          </div>

          <div v-else-if="gameState?.game_phase === 'player_kill' && gameState?.card_peeker_player_id !== currentPlayerId" class="action-panel">
            <v-alert type="error" variant="tonal">
              {{ killVoterPlayer?.name }} öldürme gücünü kullanacak...
            </v-alert>
          </div>

          <div v-else-if="gameState?.game_phase === 'authority_selection'" class="action-panel">
            <v-alert type="info" variant="tonal">
              Yetkili kart seçiyor...
            </v-alert>
          </div>

          <div v-else-if="gameState?.game_phase === 'advisor_selection'" class="action-panel">
            <v-alert type="info" variant="tonal">
              Danışman kart seçiyor...
            </v-alert>
          </div>
        </section>
      </div>

      <!-- Middle: Chat -->
      <div class="game-chat">
        <ChatPanel
          v-if="room && currentPlayerId"
          ref="chatPanelRef"
          :room-id="room.id"
          :player-id="currentPlayerId"
        />
      </div>

      <!-- Right: Players + Leave -->
      <div class="game-players">
        <PlayersList
          :players="players"
          :current-player-id="currentPlayerId"
          :show-roles="isGamePlaying || isGameFinished"
          :reveal-all-roles="isGameFinished"
        />
        <v-btn
          v-if="isGameFinished"
          color="success"
          block
          size="large"
          class="mt-3"
          prepend-icon="mdi-plus-circle"
          @click="goCreateNewRoom"
        >
          Oda Kur
        </v-btn>
        <v-btn color="error" block size="large" class="mt-3" prepend-icon="mdi-exit-to-app" @click="leaveRoom">
          {{ isGameFinished ? 'Ana Sayfaya Dön' : 'Odadan Ayrıl' }}
        </v-btn>
      </div>
    </div>

    <v-snackbar
      v-model="snackbar.show"
      :color="snackbar.color"
      :timeout="8000"
      location="top"
    >
      {{ snackbar.text }}
      <template #actions>
        <v-btn variant="text" @click="snackbar.show = false">Kapat</v-btn>
      </template>
    </v-snackbar>
  </div>
</template>

<style scoped>
.page-loading {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 100%;
  height: 100%;
  background: linear-gradient(180deg, #0A0E27 0%, #151B3D 100%);
}

.game-page {
  display: flex;
  flex-direction: column;
  width: 100%;
  height: calc(100vh - 64px);
  max-height: 100%;
  overflow: hidden;
  background: linear-gradient(180deg, #0A0E27 0%, #151B3D 100%);
}

.blocked-area {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 24px 16px;
}

.blocked-card {
  max-width: 560px;
  width: 100%;
}

/* ── Header ── */
.game-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 16px 24px;
  background: linear-gradient(135deg, #0D47A1 0%, #00838F 50%, #FF6B35 100%);
  box-shadow: 0 4px 20px rgba(0, 0, 0, 0.5);
  flex-shrink: 0;
}

.header-left {
  display: flex;
  flex-direction: column;
}

.room-name {
  font-size: 1.5rem;
  font-weight: 700;
  color: white;
  text-shadow: 0 2px 8px rgba(0, 0, 0, 0.5);
  line-height: 1.2;
}

.room-code {
  font-size: 0.85rem;
  color: rgba(255, 255, 255, 0.8);
}

.header-center {
  flex: 1;
  display: flex;
  justify-content: center;
}

.turn-badge {
  font-size: 1.25rem;
  font-weight: 700;
  color: white;
  background: rgba(255, 255, 255, 0.15);
  border: 1px solid rgba(255, 255, 255, 0.3);
  padding: 6px 20px;
  border-radius: 20px;
  backdrop-filter: blur(8px);
}

.header-right {
  display: flex;
  align-items: center;
}

/* ── Waiting ── */
.waiting-area {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 32px 24px;
}

.waiting-card {
  text-align: center;
  background: linear-gradient(145deg, #151B3D 0%, #1A2351 100%);
  border: 1px solid rgba(255, 107, 53, 0.2);
  border-radius: 16px;
  padding: 48px 40px;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
  max-width: 560px;
  width: 100%;
}

.player-chips {
  display: flex;
  flex-wrap: wrap;
  justify-content: center;
}

/* ── Game Area ── */
.game-area {
  flex: 1;
  display: grid;
  grid-template-columns: 1fr 380px 280px;
  grid-template-rows: minmax(0, 1fr);
  gap: 0;
  min-height: 0;
  overflow: hidden;
}

@media (max-width: 1200px) {
  .game-area {
    grid-template-columns: 1fr 320px 260px;
  }
}

@media (max-width: 960px) {
  .game-page {
    height: auto;
    min-height: calc(100vh - 64px);
    overflow-y: auto;
    overflow-x: hidden;
  }

  .game-area {
    display: flex;
    flex-direction: column;
    min-height: auto;
    overflow: visible;
  }

  .game-header {
    flex-wrap: wrap;
    gap: 8px;
    padding: 12px 16px;
  }

  .header-center {
    order: 3;
    flex: 0 0 100%;
    justify-content: flex-start;
  }

  .game-board {
    border-right: none;
    border-bottom: 1px solid rgba(255, 107, 53, 0.15);
    min-height: auto;
    max-height: none;
    overflow: visible;
  }

  .game-chat {
    border-right: none;
    order: 3;
    height: 360px;
    min-height: 320px;
    max-height: 420px;
    border-top: 1px solid rgba(255, 107, 53, 0.15);
  }

  .game-players {
    order: 2;
    max-height: 340px;
    flex-shrink: 0;
    overflow: hidden;
    border-top: 1px solid rgba(255, 107, 53, 0.15);
  }
}

/* ── Game Board (left) ── */
.game-board {
  padding: 12px 16px 16px;
  overflow-y: auto;
  overflow-x: hidden;
  border-right: 1px solid rgba(255, 107, 53, 0.15);
  display: flex;
  flex-direction: column;
  gap: 10px;
  min-height: 0;
}

.board-zone--hud {
  display: grid;
  grid-template-columns: minmax(200px, 260px) 1fr;
  gap: 12px;
  align-items: start;
}

.board-zone--hud .score-row {
  max-width: none;
  margin: 0;
}

.board-zone--hud :deep(.timer-card) {
  margin: 0;
  max-width: none;
  width: 100%;
}

.board-zone {
  flex-shrink: 0;
}

.board-zone--actions {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
}

.game-area--finished .game-board {
  justify-content: flex-start;
}

.game-over-panel {
  display: flex;
  flex-direction: column;
  gap: 16px;
  padding: 8px 0 4px;
}

.new-room-btn {
  font-weight: 700;
  letter-spacing: 0.3px;
}

.game-over-hint {
  margin: 0;
  font-size: 0.8rem;
  line-height: 1.4;
  text-align: center;
  color: rgba(255, 255, 255, 0.55);
}

.score-row {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 10px;
  width: 100%;
  max-width: 420px;
  margin: 0 auto;
}

.score-card {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 12px 10px;
  border-radius: 12px;
  border: 1px solid;
  background: rgba(255, 255, 255, 0.04);
  min-width: 0;
}

.score-sadik {
  border-color: rgba(67, 160, 71, 0.55);
  color: #66BB6A;
}

.score-hain {
  border-color: rgba(198, 40, 40, 0.5);
  color: #EF5350;
}

.winner-banner {
  text-align: center;
}

.winner-banner-title {
  font-size: 1.75rem;
  font-weight: 800;
  line-height: 1.2;
}

.winner-banner-subtitle {
  font-size: 0.95rem;
  opacity: 0.9;
  margin-top: 4px;
}

.score-number {
  font-size: 2rem;
  font-weight: 800;
  line-height: 1;
  margin: 2px 0;
}

.score-label {
  font-size: 0.8rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  color: rgba(255, 255, 255, 0.7);
}

.score-target {
  color: rgba(255, 255, 255, 0.4);
  font-size: 0.75rem;
}

.roles-banner {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  justify-content: center;
  flex-shrink: 0;
}

.role-badge {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 8px 16px;
  border-radius: 8px;
  font-size: 0.9rem;
  border: 1px solid;
}

.role-authority {
  background: rgba(255, 160, 0, 0.12);
  border-color: rgba(255, 160, 0, 0.4);
  color: #FFB74D;
}

.role-advisor {
  background: rgba(33, 150, 243, 0.12);
  border-color: rgba(33, 150, 243, 0.4);
  color: #64B5F6;
}

.phase-actions {
  overflow-y: auto;
  overflow-x: hidden;
  -webkit-overflow-scrolling: touch;
}

.phase-actions--voting {
  overflow-y: auto;
}

.action-panel {
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid rgba(255, 107, 53, 0.15);
  border-radius: 12px;
  padding: 20px;
}

.action-panel--voting {
  padding: 12px 14px;
  overflow: visible;
}

.vote-phase-title {
  font-size: 1rem;
  font-weight: 700;
  margin-bottom: 8px;
}

.vote-alert {
  margin-bottom: 8px !important;
  font-size: 0.85rem;
}

.vote-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(110px, 1fr));
  gap: 8px;
  margin-bottom: 10px;
  width: 100%;
}

.vote-option {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 8px 10px;
  border-radius: 8px;
  border: 1px solid rgba(255, 107, 53, 0.25);
  background: rgba(255, 255, 255, 0.04);
  color: rgba(255, 255, 255, 0.9);
  cursor: pointer;
  text-align: left;
  font-size: 0.85rem;
  transition: background 0.15s ease, border-color 0.15s ease;
}

.vote-option:hover {
  background: rgba(255, 107, 53, 0.12);
}

.vote-option--selected {
  border-color: rgba(255, 107, 53, 0.7);
  background: rgba(255, 107, 53, 0.2);
}

.vote-option--danger {
  border-color: rgba(198, 40, 40, 0.45);
}

.vote-option--danger:hover {
  background: rgba(198, 40, 40, 0.15);
}

.vote-option--disabled,
.vote-option--disabled:hover {
  cursor: not-allowed;
  opacity: 0.42;
  background: rgba(255, 255, 255, 0.035);
}

.vote-option-name {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.vote-submit-btn,
.vote-finish-btn {
  margin-top: 6px;
}

.board-zone--status :deep(.timer-card) {
  flex-shrink: 0;
  max-width: 280px;
  margin: 0 auto;
  width: 100%;
}

.policy-card-grid {
  display: grid;
  grid-template-columns: repeat(3, minmax(120px, 1fr));
  gap: 12px;
}

.policy-card-grid--two {
  grid-template-columns: repeat(2, minmax(140px, 1fr));
}

.policy-card {
  position: relative;
  min-height: 190px;
  padding: 16px 12px;
  border: 1px solid rgba(255, 255, 255, 0.16);
  border-radius: 8px;
  color: white;
  cursor: pointer;
  overflow: hidden;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 12px;
  isolation: isolate;
  transition: transform 0.18s ease, border-color 0.18s ease, box-shadow 0.18s ease;
}

.policy-card::before {
  content: '';
  position: absolute;
  inset: 8px;
  border: 1px solid rgba(255, 255, 255, 0.16);
  border-radius: 6px;
  z-index: -1;
}

.policy-card::after {
  content: '';
  position: absolute;
  inset: -40%;
  opacity: 0.22;
  transform: rotate(24deg);
  z-index: -2;
}

.policy-card:hover {
  transform: translateY(-3px);
}

.policy-card--selected {
  transform: translateY(-5px);
  border-color: rgba(255, 255, 255, 0.7);
  box-shadow: 0 16px 34px rgba(0, 0, 0, 0.38), 0 0 0 2px rgba(255, 255, 255, 0.16);
}

.policy-card--safe {
  background:
    radial-gradient(circle at 50% 18%, rgba(189, 255, 198, 0.18), transparent 34%),
    linear-gradient(160deg, #123f32 0%, #1f7a4e 48%, #0c241d 100%);
}

.policy-card--safe::after {
  background: repeating-linear-gradient(
    90deg,
    rgba(166, 255, 189, 0.5) 0,
    rgba(166, 255, 189, 0.5) 4px,
    transparent 4px,
    transparent 18px
  );
}

.policy-card--kaos {
  background:
    radial-gradient(circle at 50% 18%, rgba(255, 120, 98, 0.22), transparent 34%),
    linear-gradient(160deg, #451219 0%, #8d1f2c 48%, #1f0c12 100%);
}

.policy-card--kaos::after {
  background: repeating-linear-gradient(
    90deg,
    rgba(255, 132, 100, 0.5) 0,
    rgba(255, 132, 100, 0.5) 4px,
    transparent 4px,
    transparent 18px
  );
}

.policy-card-top {
  position: absolute;
  top: 14px;
  left: 14px;
  width: 26px;
  height: 26px;
  border-radius: 50%;
  display: grid;
  place-items: center;
  background: rgba(0, 0, 0, 0.22);
  border: 1px solid rgba(255, 255, 255, 0.18);
  font-size: 0.82rem;
  font-weight: 800;
}

.policy-card-icon {
  filter: drop-shadow(0 8px 18px rgba(0, 0, 0, 0.45));
}

.policy-card-title {
  font-size: 1.35rem;
  font-weight: 900;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  text-shadow: 0 2px 12px rgba(0, 0, 0, 0.45);
}

.policy-card-line {
  width: 54px;
  height: 3px;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.72);
}

.vote-results {
  background: rgba(255, 255, 255, 0.04);
  border-radius: 8px;
  padding: 8px 10px;
  margin-top: 8px;
}

.vote-results-title {
  font-size: 0.8rem;
  font-weight: 600;
  margin-bottom: 6px;
  color: rgba(255, 255, 255, 0.75);
}

.vote-bars {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.vote-bar-row {
  display: flex;
  align-items: center;
  gap: 8px;
}

.vote-name {
  min-width: 90px;
  font-size: 0.85rem;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.85);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.vote-bar-wrap {
  flex: 1;
  height: 8px;
  background: rgba(255, 255, 255, 0.08);
  border-radius: 4px;
  overflow: hidden;
}

.vote-bar-fill {
  height: 100%;
  background: linear-gradient(90deg, #FF6B35, #FF9B35);
  border-radius: 4px;
  transition: width 0.4s ease;
  min-width: 4px;
}

.vote-count {
  min-width: 20px;
  text-align: right;
  font-size: 0.85rem;
  font-weight: 700;
  color: #FF6B35;
}

.private-card-reveal {
  text-align: center;
  padding: 20px;
  border-radius: 12px;
  border: 2px dashed rgba(255, 193, 7, 0.6);
  background: rgba(255, 193, 7, 0.08);
  animation: fadeInCard 0.4s ease;
  flex-shrink: 0;
}

.private-card-label {
  font-size: 0.75rem;
  text-transform: uppercase;
  letter-spacing: 1px;
  color: rgba(255, 193, 7, 0.9);
  margin-bottom: 8px;
}

.private-card-player {
  font-size: 1.1rem;
  font-weight: 600;
  margin-bottom: 12px;
}

.private-card-value {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 8px;
  font-size: 1.75rem;
  font-weight: 800;
}

.private-card-value.card-sadik {
  color: #66BB6A;
}

.private-card-value.card-hain {
  color: #EF5350;
}

.private-card-value.card-agent {
  color: #EF5350;
}

.private-card-value.card-unknown {
  font-size: 0.95rem;
  font-weight: 500;
  color: rgba(255, 255, 255, 0.7);
}

@keyframes fadeInCard {
  from { opacity: 0; transform: scale(0.95); }
  to { opacity: 1; transform: scale(1); }
}

/* ── Chat (middle) ── */
.game-chat {
  border-right: 1px solid rgba(255, 107, 53, 0.15);
  display: flex;
  flex-direction: column;
  overflow: hidden;
  min-height: 0;
  height: 100%;
  max-height: 100%;
}

.game-chat :deep(.v-card) {
  height: 100% !important;
  border-radius: 0 !important;
  border: none !important;
  box-shadow: none !important;
}

/* ── Players (right) ── */
.game-players {
  padding: 16px;
  display: flex;
  flex-direction: column;
  gap: 8px;
  min-height: 0;
  overflow: hidden;
}

.game-players :deep(.players-card) {
  flex: 1 1 auto;
  min-height: 0;
}

.game-players :deep(.players-list-scroll.v-list) {
  max-height: none !important;
  overflow-y: auto !important;
  overflow-x: hidden !important;
}

/* ── Dialogs ── */
.dialog-card {
  background: linear-gradient(145deg, #151B3D 0%, #1A2351 100%) !important;
  border: 1px solid rgba(255, 107, 53, 0.3) !important;
}

/* ── Vuetify overrides ── */
.cursor-pointer {
  cursor: pointer;
}

:deep(.v-card) {
  background: linear-gradient(145deg, #151B3D 0%, #1A2351 100%) !important;
  border: 1px solid rgba(255, 107, 53, 0.2);
  box-shadow: 0 4px 16px rgba(0, 0, 0, 0.3);
}

:deep(.v-btn) {
  transition: all 0.2s ease;
  font-weight: 600;
}

:deep(.v-btn[disabled]) {
  opacity: 0.4;
}

:deep(.v-list) {
  background: transparent !important;
  max-height: none !important;
  overflow: visible !important;
}

.action-panel--voting :deep(.v-list) {
  overflow: visible !important;
}

:deep(.v-list-item) {
  background: rgba(255, 255, 255, 0.04);
  margin-bottom: 4px;
}

:deep(.v-list-item.v-list-item--active) {
  background: rgba(255, 107, 53, 0.2) !important;
}

:deep(.v-list-item.cursor-pointer:hover) {
  background: rgba(255, 107, 53, 0.12);
}

:deep(.v-chip) {
  font-weight: 600;
}

:deep(.v-alert) {
  font-weight: 500;
}

@keyframes pulse-sadik {
  0%, 100% { box-shadow: 0 0 0 0 rgba(67, 160, 71, 0); }
  50% { box-shadow: 0 0 12px 2px rgba(67, 160, 71, 0.35); }
}

@keyframes pulse-hain {
  0%, 100% { box-shadow: 0 0 0 0 rgba(198, 40, 40, 0); }
  50% { box-shadow: 0 0 12px 2px rgba(198, 40, 40, 0.35); }
}

.score-card--pulse.score-sadik {
  animation: pulse-sadik 2.5s ease-in-out infinite;
}

.score-card--pulse.score-hain {
  animation: pulse-hain 2.5s ease-in-out infinite;
}

@media (max-width: 960px) {
  .board-zone--hud {
    grid-template-columns: 1fr;
  }

  .game-board {
    padding: 10px 12px 12px;
  }

  .score-row {
    max-width: none;
  }

  .score-number {
    font-size: 1.75rem;
  }

  .winner-banner-title {
    font-size: 1.4rem;
  }

  .vote-grid {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }

  .policy-card-grid,
  .policy-card-grid--two {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }

  .policy-card {
    min-height: 160px;
  }

  .action-panel {
    padding: 14px;
  }
}

@media (max-width: 600px) {
  .game-page {
    min-height: calc(100vh - 56px);
  }

  .game-header {
    align-items: flex-start;
    padding: 10px 12px;
  }

  .room-name {
    font-size: 1.1rem;
  }

  .room-code {
    font-size: 0.76rem;
  }

  .turn-badge {
    width: 100%;
    padding: 6px 10px;
    border-radius: 8px;
    font-size: 0.95rem;
    text-align: center;
  }

  .game-board {
    padding: 10px;
    gap: 8px;
  }

  .waiting-area {
    align-items: flex-start;
    padding: 14px 10px;
    overflow-y: auto;
  }

  .waiting-card {
    padding: 22px 14px;
  }

  .board-zone--hud {
    gap: 8px;
  }

  .score-row {
    gap: 8px;
  }

  .score-card {
    padding: 10px 8px;
  }

  .score-number {
    font-size: 1.45rem;
  }

  .score-label,
  .score-target {
    font-size: 0.68rem;
  }

  .roles-banner {
    flex-direction: column;
    align-items: stretch;
  }

  .role-badge {
    justify-content: center;
    padding: 7px 10px;
  }

  .phase-actions {
    overflow: visible;
  }

  .action-panel {
    padding: 12px;
    border-radius: 8px;
  }

  .vote-grid {
    grid-template-columns: 1fr;
    gap: 7px;
  }

  .vote-option {
    min-height: 42px;
    padding: 9px 10px;
  }

  .policy-card-grid,
  .policy-card-grid--two {
    grid-template-columns: 1fr;
    gap: 10px;
  }

  .policy-card {
    min-height: 124px;
    padding: 14px 10px;
    gap: 8px;
  }

  .policy-card-title {
    font-size: 1.1rem;
  }

  .policy-card-icon {
    transform: scale(0.9);
  }

  .winner-banner-title {
    font-size: 1.25rem;
  }

  .winner-banner-subtitle {
    font-size: 0.84rem;
  }

  .game-players {
    padding: 10px;
    max-height: 330px;
  }

  .game-chat {
    height: 340px;
    min-height: 300px;
    max-height: 360px;
  }

  .vote-name {
    min-width: 64px;
    max-width: 72px;
  }
}

@media (max-width: 768px) {
  .game-page,
  .game-area,
  .game-board,
  .game-chat,
  .game-players {
    width: 100%;
    max-width: 100vw;
    min-width: 0;
    overflow-x: hidden;
  }

  .game-page {
    height: auto;
    min-height: calc(100dvh - 64px);
    max-height: none;
    overflow-y: auto;
  }

  .game-area {
    display: flex !important;
    flex-direction: column;
    gap: 8px;
    padding: 8px;
    min-height: auto;
    overflow: visible;
  }

  .game-board {
    order: 1;
    padding: 0;
    gap: 8px;
    border-right: none;
    border-bottom: none;
    overflow: visible;
  }

  .game-players {
    order: 2;
    padding: 0;
    max-height: 280px;
    overflow: hidden;
    border-top: none;
  }

  .game-chat {
    order: 3;
    height: 260px;
    min-height: 240px;
    max-height: 280px;
    border-right: none;
    border-top: none;
  }

  .game-header {
    position: sticky;
    top: 0;
    z-index: 20;
    gap: 8px;
    padding: 10px 12px;
  }

  .header-left,
  .header-right,
  .header-center {
    min-width: 0;
  }

  .header-left {
    flex: 1 1 150px;
  }

  .header-right {
    flex: 0 0 auto;
  }

  .header-center {
    order: 3;
    flex: 1 0 100%;
  }

  .room-name {
    max-width: 100%;
    font-size: 1rem;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .room-code {
    font-size: 0.72rem;
  }

  .turn-badge {
    width: 100%;
    min-height: 36px;
    padding: 6px 10px;
    border-radius: 8px;
    font-size: 0.92rem;
    text-align: center;
  }

  .board-zone--hud {
    position: sticky;
    top: 92px;
    z-index: 12;
    grid-template-columns: 1fr;
    gap: 8px;
    padding: 8px;
    border: 1px solid rgba(255, 107, 53, 0.18);
    border-radius: 8px;
    background: rgba(10, 14, 39, 0.96);
    backdrop-filter: blur(12px);
  }

  .score-row {
    grid-template-columns: 1fr 1fr;
    gap: 8px;
    max-width: none;
  }

  .score-card {
    min-height: 72px;
    padding: 8px;
    border-radius: 8px;
  }

  .score-card .v-icon {
    font-size: 20px !important;
  }

  .score-number {
    font-size: 1.35rem;
  }

  .score-label {
    font-size: 0.68rem;
  }

  .score-target {
    font-size: 0.66rem;
  }

  .roles-banner {
    display: grid;
    grid-template-columns: 1fr;
    gap: 6px;
  }

  .role-badge {
    min-height: 38px;
    justify-content: center;
    padding: 7px 10px;
    font-size: 0.82rem;
    text-align: center;
  }

  .board-zone--actions {
    min-height: auto;
  }

  .phase-actions {
    overflow: visible;
  }

  .action-panel {
    padding: 12px;
    border-radius: 8px;
  }

  .action-panel :deep(.v-alert) {
    margin-bottom: 10px !important;
    font-size: 0.84rem;
  }

  .action-panel :deep(.v-btn),
  .game-players :deep(.v-btn) {
    min-height: 44px;
  }

  .vote-grid {
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 8px;
  }

  .vote-option {
    min-height: 44px;
    padding: 9px 10px;
    font-size: 0.84rem;
  }

  .vote-results {
    padding: 8px;
  }

  .vote-bar-row {
    gap: 6px;
  }

  .vote-name {
    min-width: 72px;
    max-width: 92px;
    font-size: 0.78rem;
  }

  .policy-card-grid,
  .policy-card-grid--two {
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 8px;
  }

  .policy-card {
    min-height: 132px;
    padding: 12px 8px;
    gap: 8px;
  }

  .policy-card-top {
    top: 10px;
    left: 10px;
    width: 24px;
    height: 24px;
  }

  .policy-card-title {
    font-size: 1.05rem;
  }

  .policy-card-line {
    width: 42px;
  }

  .private-card-reveal {
    padding: 14px;
  }

  .private-card-value {
    font-size: 1.25rem;
  }

  .waiting-area {
    align-items: flex-start;
    padding: 10px;
    overflow-y: auto;
  }

  .waiting-card {
    padding: 20px 14px;
    border-radius: 8px;
  }
}

@media (max-width: 480px) {
  .game-page {
    min-height: calc(100dvh - 56px);
  }

  .game-area {
    gap: 6px;
    padding: 6px;
  }

  .game-header {
    padding: 8px 10px;
  }

  .header-left {
    flex-basis: 132px;
  }

  .header-right :deep(.v-chip) {
    height: 30px;
    padding: 0 8px;
    font-size: 0.72rem;
  }

  .board-zone--hud {
    top: 86px;
    padding: 7px;
  }

  .score-card {
    min-height: 64px;
  }

  .score-number {
    font-size: 1.2rem;
  }

  .action-panel {
    padding: 10px;
  }

  .vote-grid {
    grid-template-columns: 1fr;
  }

  .policy-card-grid,
  .policy-card-grid--two {
    grid-template-columns: 1fr;
  }

  .policy-card {
    min-height: 110px;
  }

  .game-players {
    max-height: 245px;
  }

  .game-chat {
    height: 220px;
    min-height: 210px;
    max-height: 240px;
  }

  .winner-banner-title {
    font-size: 1.15rem;
  }

  .winner-banner-subtitle,
  .game-over-hint {
    font-size: 0.78rem;
  }
}
</style>

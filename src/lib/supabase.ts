import { computed, ref } from 'vue'
import { createClient } from '@supabase/supabase-js'

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL as string | undefined
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined

const INVALID_ENV_VALUES = new Set(['', 'undefined', 'null', 'your_supabase_url', 'your-anon-key'])

const isValidEnvValue = (value: string | undefined): value is string => {
  if (!value || typeof value !== 'string') return false
  const trimmed = value.trim()
  if (!trimmed || INVALID_ENV_VALUES.has(trimmed.toLowerCase())) return false
  if (/^your[-_]/i.test(trimmed) || /^replace/i.test(trimmed)) return false
  return true
}

export const supabaseEnabled = isValidEnvValue(supabaseUrl) && isValidEnvValue(supabaseAnonKey)

/** null = henüz test edilmedi, true/false = canlı bağlantı sonucu */
export const supabaseConnected = ref<boolean | null>(null)

export const isSupabaseConfigured = computed(
  () => supabaseEnabled && supabaseConnected.value !== false
)

export const showSupabaseSetupBanner = computed(
  () => !supabaseEnabled || supabaseConnected.value === false
)

export const supabaseConfigError = supabaseEnabled
  ? null
  : 'Supabase ayarları eksik: VITE_SUPABASE_URL ve VITE_SUPABASE_ANON_KEY tanımlı değil (.env.local).'

export async function verifySupabaseConnection(): Promise<boolean> {
  if (!supabaseEnabled) {
    supabaseConnected.value = false
    return false
  }

  try {
    const { error } = await supabase.from('rooms').select('id').limit(1)
    const ok = !error
    supabaseConnected.value = ok
    return ok
  } catch {
    supabaseConnected.value = false
    return false
  }
}

export function markSupabaseConnected() {
  if (supabaseEnabled) supabaseConnected.value = true
}

type SupabaseErrorShape = { message: string }

const disabledError = (action: string): SupabaseErrorShape => ({
  message: `${action} yapılamadı. Supabase ayarlı değil.`,
})

const createDisabledSupabase = () => {
  const fail = async (action: string) => ({ data: null, error: disabledError(action) })

  const chain = (action: string) => ({
    select: async () => fail(`${action}.select`),
    maybeSingle: async () => fail(`${action}.maybeSingle`),
    single: async () => fail(`${action}.single`),
    insert: async () => fail(`${action}.insert`),
    update: async () => fail(`${action}.update`),
    delete: async () => fail(`${action}.delete`),
    order: () => chain(`${action}.order`),
    limit: () => chain(`${action}.limit`),
    eq: () => chain(`${action}.eq`),
    in: () => chain(`${action}.in`),
  })

  return {
    from: (table: string) => chain(`from(${table})`),
    channel: () => ({
      on: () => ({
        subscribe: (cb?: (status: string) => void) => {
          cb?.('DISABLED')
          return { __disabled: true }
        },
      }),
      subscribe: (cb?: (status: string) => void) => {
        cb?.('DISABLED')
        return { __disabled: true }
      },
    }),
    removeChannel: () => {},
  }
}

export const supabase = supabaseEnabled
  ? createClient(supabaseUrl!, supabaseAnonKey!, {
    realtime: {
      params: {
        eventsPerSecond: 10,
      },
    },
  })
  : (createDisabledSupabase() as any)

export interface Room {
  id: string
  room_code: string
  name: string
  status: 'waiting' | 'playing' | 'finished'
  max_players: number
  created_at: string
  started_at?: string
  finished_at?: string
  winning_team?: 'sadik' | 'hain'
}

export interface Player {
  id: string
  room_id: string
  name: string
  role?: 'sadik' | 'hain' | 'ajan'
  is_alive: boolean
  is_host: boolean
  joined_at: string
}

export interface GameState {
  id: string
  room_id: string
  current_turn: number
  current_authority_player_id?: string
  current_advisor_player_id?: string
  safe_cards_played: number
  kaos_cards_played: number
  game_phase: 'discussion' | 'voting' | 'authority_selection' | 'advisor_selection' | 'reveal' | 'card_peek' | 'role_peek' | 'authority_view_role' | 'authority_kill' | 'player_kill'
  card_peeker_player_id?: string
  cards_in_deck: string[]
  selected_cards: string[]
  advisor_cards: string[]
  phase_end_time?: string
  consecutive_kaos_count: number
  advisor_can_view_role: boolean
  advisor_can_investigate: boolean
  viewed_player_id?: string
  last_advisor_id?: string
  current_phase_number: number
  updated_at: string
}

export interface Message {
  id: string
  room_id: string
  player_id?: string
  message: string
  is_system: boolean
  created_at: string
  players?: {
    name: string
  }
}

export interface Vote {
  id: string
  room_id: string
  turn_number: number
  voter_player_id: string
  voted_for_player_id?: string
  created_at: string
}

export interface GameAction {
  id: string
  room_id: string
  turn_number: number
  action_type: 'card_played' | 'vote_cast' | 'role_reveal' | 'game_end' | 'phase_change'
  player_id?: string
  data: Record<string, any>
  created_at: string
}

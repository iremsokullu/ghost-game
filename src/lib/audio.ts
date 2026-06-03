import { ref } from 'vue'

type Team = 'sadik' | 'hain'
type CardType = 'safe' | 'kaos'

const soundStorageKey = 'ghost:sound-enabled'

export const soundEnabled = ref(localStorage.getItem(soundStorageKey) !== 'false')

let audioContext: AudioContext | null = null
const previousCleanup = (globalThis as typeof globalThis & { __ghostAudioCleanup?: () => void }).__ghostAudioCleanup
previousCleanup?.()

const getContext = () => {
  audioContext ??= new AudioContext()
  if (audioContext.state === 'suspended') void audioContext.resume()
  return audioContext
}

const createGain = (volume: number) => {
  const ctx = getContext()
  const gain = ctx.createGain()
  gain.gain.setValueAtTime(0.0001, ctx.currentTime)
  gain.gain.exponentialRampToValueAtTime(volume, ctx.currentTime + 0.015)
  gain.connect(ctx.destination)
  return gain
}

const tone = (
  frequency: number,
  duration: number,
  options: { type?: OscillatorType; volume?: number; delay?: number; endFrequency?: number } = {}
) => {
  if (!soundEnabled.value) return

  const ctx = getContext()
  const delay = options.delay ?? 0
  const start = ctx.currentTime + delay
  const end = start + duration
  const oscillator = ctx.createOscillator()
  const gain = createGain(options.volume ?? 0.08)

  oscillator.type = options.type ?? 'sine'
  oscillator.frequency.setValueAtTime(frequency, start)
  if (options.endFrequency) {
    oscillator.frequency.exponentialRampToValueAtTime(options.endFrequency, end)
  }
  gain.gain.exponentialRampToValueAtTime(0.0001, end)

  oscillator.connect(gain)
  oscillator.start(start)
  oscillator.stop(end + 0.03)
}

export const playButtonClick = () => {
  tone(520, 0.055, { type: 'triangle', volume: 0.035, endFrequency: 760 })
}

export const playCardReveal = (card: CardType) => {
  tone(card === 'safe' ? 620 : 190, 0.16, {
    type: card === 'safe' ? 'triangle' : 'sawtooth',
    volume: card === 'safe' ? 0.07 : 0.055,
    endFrequency: card === 'safe' ? 980 : 95,
  })
  tone(card === 'safe' ? 930 : 280, 0.12, {
    type: 'sine',
    volume: 0.045,
    delay: 0.07,
    endFrequency: card === 'safe' ? 1240 : 135,
  })
}

export const playCardDraw = () => {
  tone(260, 0.08, { type: 'triangle', volume: 0.045, endFrequency: 390 })
  tone(520, 0.09, { type: 'sine', volume: 0.035, delay: 0.045, endFrequency: 680 })
}

export const playGameStart = () => {
  tone(330, 0.12, { type: 'triangle', volume: 0.055 })
  tone(494, 0.13, { type: 'triangle', volume: 0.06, delay: 0.11 })
  tone(740, 0.18, { type: 'triangle', volume: 0.065, delay: 0.22 })
}

export const playGameEnd = (winner: Team) => {
  if (winner === 'sadik') {
    tone(523, 0.13, { type: 'triangle', volume: 0.07 })
    tone(659, 0.13, { type: 'triangle', volume: 0.07, delay: 0.12 })
    tone(784, 0.28, { type: 'triangle', volume: 0.08, delay: 0.24 })
    return
  }

  tone(220, 0.18, { type: 'sawtooth', volume: 0.055, endFrequency: 165 })
  tone(147, 0.32, { type: 'sine', volume: 0.06, delay: 0.16, endFrequency: 110 })
}

export const setSoundEnabled = (enabled: boolean) => {
  soundEnabled.value = enabled
  localStorage.setItem(soundStorageKey, String(enabled))
}

export const toggleSound = () => {
  setSoundEnabled(!soundEnabled.value)
  if (soundEnabled.value) playButtonClick()
}

const stopMusicNodes = () => {}

;(globalThis as typeof globalThis & {
  __ghostAudioCleanup?: () => void
}).__ghostAudioCleanup = stopMusicNodes

export const stopMusic = () => {
  stopMusicNodes()
}

export const unlockAudio = () => {
  getContext()
}

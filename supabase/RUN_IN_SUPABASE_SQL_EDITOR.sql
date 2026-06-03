/*
  GHOST — Tur 2+ ilerleme (tek dosya, Supabase SQL Editor'da bir kez çalıştırın)

  Sorunlar:
  - advisor_can_investigate sütunu yoksa nextTurn UPDATE başarısız → reveal'de takılma
  - Eski game_states_game_phase_check yeni fazları (role_peek, player_kill) reddediyor
  - votes DELETE politikası yoksa Kaos sonrası oylar temizlenemiyor
*/

-- ========== game_states sütunları ==========
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'game_states' AND column_name = 'advisor_can_investigate'
  ) THEN
    ALTER TABLE game_states ADD COLUMN advisor_can_investigate boolean DEFAULT false;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'game_states' AND column_name = 'card_peeker_player_id'
  ) THEN
    ALTER TABLE game_states ADD COLUMN card_peeker_player_id uuid REFERENCES players(id) ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'game_states' AND column_name = 'consecutive_kaos_count'
  ) THEN
    ALTER TABLE game_states ADD COLUMN consecutive_kaos_count integer DEFAULT 0;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'game_states' AND column_name = 'advisor_can_view_role'
  ) THEN
    ALTER TABLE game_states ADD COLUMN advisor_can_view_role boolean DEFAULT false;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'game_states' AND column_name = 'viewed_player_id'
  ) THEN
    ALTER TABLE game_states ADD COLUMN viewed_player_id uuid REFERENCES players(id) ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'game_states' AND column_name = 'last_advisor_id'
  ) THEN
    ALTER TABLE game_states ADD COLUMN last_advisor_id uuid REFERENCES players(id) ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'game_states' AND column_name = 'current_phase_number'
  ) THEN
    ALTER TABLE game_states ADD COLUMN current_phase_number integer DEFAULT 1;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'game_states' AND column_name = 'phase_end_time'
  ) THEN
    ALTER TABLE game_states ADD COLUMN phase_end_time timestamptz;
  END IF;
END $$;

-- Takılı kalmış reveal → tartışmaya (acil kurtarma; istemci de otomatik dener)
UPDATE game_states
SET
  game_phase = 'discussion',
  phase_end_time = now() + interval '60 seconds',
  current_authority_player_id = NULL,
  current_advisor_player_id = NULL,
  advisor_can_view_role = false,
  advisor_can_investigate = false,
  card_peeker_player_id = NULL,
  viewed_player_id = NULL,
  consecutive_kaos_count = 0,
  selected_cards = '[]'::jsonb,
  advisor_cards = '[]'::jsonb
WHERE game_phase = 'reveal'
  AND phase_end_time IS NOT NULL
  AND phase_end_time < now() - interval '15 seconds';

-- ========== game_phase: çift constraint temizliği ==========
ALTER TABLE game_states DROP CONSTRAINT IF EXISTS valid_phase;
ALTER TABLE game_states DROP CONSTRAINT IF EXISTS game_states_game_phase_check;

ALTER TABLE game_states ADD CONSTRAINT valid_phase
CHECK (game_phase IN (
  'discussion',
  'voting',
  'authority_selection',
  'advisor_selection',
  'reveal',
  'card_peek',
  'role_peek',
  'authority_view_role',
  'authority_kill',
  'player_kill',
  'advisor_kill',
  'game_over',
  'waiting'
));

-- ========== votes DELETE ==========
DROP POLICY IF EXISTS "Anyone can delete votes" ON votes;
CREATE POLICY "Anyone can delete votes"
  ON votes FOR DELETE
  TO public
  USING (true);

-- ========== game_states UPDATE (WITH CHECK) ==========
DROP POLICY IF EXISTS "Anyone can update game states" ON game_states;
CREATE POLICY "Anyone can update game states"
  ON game_states FOR UPDATE
  TO public
  USING (true)
  WITH CHECK (true);

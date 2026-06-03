/*
  # Kart Görme Sistemi (2. Kaos)

  - card_peeker_player_id: 2. kaos sonrası oylamayla seçilen, kart görebilen oyuncu
  - card_peek fazı eklendi
*/

ALTER TABLE game_states DROP CONSTRAINT IF EXISTS valid_phase;
ALTER TABLE game_states DROP CONSTRAINT IF EXISTS game_states_game_phase_check;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'game_states' AND column_name = 'card_peeker_player_id'
  ) THEN
    ALTER TABLE game_states ADD COLUMN card_peeker_player_id uuid REFERENCES players(id) ON DELETE SET NULL;
  END IF;
END $$;

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
  'player_kill'
));

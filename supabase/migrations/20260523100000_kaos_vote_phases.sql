/*
  # Kaos oylama fazları (2. ve 3. art arda Kaos)

  - role_peek: seçilen oyuncu birinin rolünü gizlice görür
  - player_kill: 3. kaos sonrası oylama kazananı birini eleyebilir
*/

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
  'player_kill'
));

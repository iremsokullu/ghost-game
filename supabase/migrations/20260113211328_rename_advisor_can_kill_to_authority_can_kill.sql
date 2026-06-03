/*
  # Rename advisor_can_kill to authority_can_kill
  
  1. Changes
    - Rename `advisor_can_kill` column to `authority_can_kill` in game_states table
    - This fixes the incorrect naming - it should be the authority (yetkili) who kills after 3 kaos cards, not the advisor (danışan)
  
  2. Security
    - Maintain existing RLS policies
*/

-- Rename the column
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'game_states' AND column_name = 'advisor_can_kill'
  ) THEN
    ALTER TABLE game_states RENAME COLUMN advisor_can_kill TO authority_can_kill;
  END IF;
END $$;
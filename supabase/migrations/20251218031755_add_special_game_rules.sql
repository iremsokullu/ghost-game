/*
  # Add Special Game Rules

  1. Changes to game_states table
    - Add `consecutive_kaos_count` (integer) - Tracks consecutive kaos cards (max 3)
    - Add `advisor_can_kill` (boolean) - Whether advisor has kill power after 3 kaos
    - Add `agent_can_vote` (boolean) - Whether agent gains voting power after 3 kaos
    - Add `current_phase_number` (integer) - Current phase number (1-6, democracy wins at 6)
  
  2. Game Rules Implementation
    - When phase 6 Safe card is successfully placed, democracy (sadik) team wins
    - After 3 consecutive kaos cards, advisor gets power to kill one player
    - If advisor kills the agent, game ends with traitor victory
    - After 3 consecutive kaos, if agent gets voting power, traitors + agent win
  
  3. Security
    - Maintain existing RLS policies
*/

-- Add new columns to game_states table
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'game_states' AND column_name = 'consecutive_kaos_count'
  ) THEN
    ALTER TABLE game_states ADD COLUMN consecutive_kaos_count integer DEFAULT 0;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'game_states' AND column_name = 'advisor_can_kill'
  ) THEN
    ALTER TABLE game_states ADD COLUMN advisor_can_kill boolean DEFAULT false;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'game_states' AND column_name = 'agent_can_vote'
  ) THEN
    ALTER TABLE game_states ADD COLUMN agent_can_vote boolean DEFAULT false;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'game_states' AND column_name = 'current_phase_number'
  ) THEN
    ALTER TABLE game_states ADD COLUMN current_phase_number integer DEFAULT 1;
  END IF;
END $$;
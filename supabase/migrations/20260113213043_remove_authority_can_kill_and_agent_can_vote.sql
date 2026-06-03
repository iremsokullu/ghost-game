/*
  # Remove unused columns from game_states
  
  1. Changes
    - Remove `authority_can_kill` column (kill feature completely removed)
    - Remove `agent_can_vote` column (not used in game logic)
  
  2. Security
    - Maintain existing RLS policies
*/

-- Remove authority_can_kill column
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'game_states' AND column_name = 'authority_can_kill'
  ) THEN
    ALTER TABLE game_states DROP COLUMN authority_can_kill;
  END IF;
END $$;

-- Remove agent_can_vote column
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'game_states' AND column_name = 'agent_can_vote'
  ) THEN
    ALTER TABLE game_states DROP COLUMN agent_can_vote;
  END IF;
END $$;
/*
  # Update Game Phase Constraint

  1. Changes
    - Update game_phase constraint to include 'advisor_kill' phase
  
  2. Security
    - Maintain existing RLS policies
*/

-- Drop the old constraint
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.constraint_column_usage
    WHERE constraint_name = 'valid_phase' AND table_name = 'game_states'
  ) THEN
    ALTER TABLE game_states DROP CONSTRAINT valid_phase;
  END IF;
END $$;

-- Add the new constraint with advisor_kill phase
ALTER TABLE game_states
ADD CONSTRAINT valid_phase
CHECK (game_phase IN ('discussion', 'voting', 'authority_selection', 'advisor_selection', 'reveal', 'advisor_kill'));
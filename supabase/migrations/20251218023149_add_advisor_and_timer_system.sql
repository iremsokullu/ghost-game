/*
  # Add Advisor and Timer System

  ## Overview
  Updates game mechanics to include advisor role and timer system:
  - Authority draws 3 cards, discards 1, gives 2 to advisor
  - Advisor discards 1, reveals the final card
  - Each phase has a time limit

  ## Changes

  ### 1. Update game_states table
  - Add `current_advisor_player_id` - The advisor for current turn
  - Add `phase_end_time` - Timestamp when current phase ends
  - Add `selected_cards` - 3 cards drawn by authority
  - Add `advisor_cards` - 2 cards given to advisor
  - Update `game_phase` to include new phases

  ### 2. Game Phases
  - 'discussion' - Discussion phase (60 seconds)
  - 'authority_selection' - Authority selects from 3 cards (30 seconds)
  - 'advisor_selection' - Advisor selects from 2 cards (30 seconds)
  - 'reveal' - Card is revealed (5 seconds)

  ## Security
  - Maintain RLS policies
  - Ensure only current authority/advisor can see their cards
*/

-- Drop the existing phase constraint
ALTER TABLE game_states DROP CONSTRAINT IF EXISTS valid_phase;

-- Add new columns to game_states
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'game_states' AND column_name = 'current_advisor_player_id'
  ) THEN
    ALTER TABLE game_states ADD COLUMN current_advisor_player_id uuid REFERENCES players(id) ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'game_states' AND column_name = 'phase_end_time'
  ) THEN
    ALTER TABLE game_states ADD COLUMN phase_end_time timestamptz;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'game_states' AND column_name = 'selected_cards'
  ) THEN
    ALTER TABLE game_states ADD COLUMN selected_cards jsonb DEFAULT '[]'::jsonb;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'game_states' AND column_name = 'advisor_cards'
  ) THEN
    ALTER TABLE game_states ADD COLUMN advisor_cards jsonb DEFAULT '[]'::jsonb;
  END IF;
END $$;

-- Add updated phase constraint
ALTER TABLE game_states ADD CONSTRAINT valid_phase 
  CHECK (game_phase IN ('discussion', 'authority_selection', 'advisor_selection', 'reveal'));
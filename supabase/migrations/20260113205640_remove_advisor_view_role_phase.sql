/*
  # Remove advisor_view_role Phase

  1. Changes
    - Remove 'advisor_view_role' option from game_phase check constraint
    - Update any existing game_states that might be in advisor_view_role phase
    - This simplifies the game flow by removing the role viewing mechanic after 2nd chaos card
  
  2. Notes
    - The game will now go directly from advisor_selection to next round after 2nd chaos card
    - This prevents the game from getting stuck after round 2
*/

-- First, update any existing game_states that might be in advisor_view_role phase
UPDATE game_states 
SET game_phase = 'discussion' 
WHERE game_phase = 'advisor_view_role';

-- Drop the existing constraint
ALTER TABLE game_states DROP CONSTRAINT IF EXISTS game_states_game_phase_check;

-- Add new constraint without advisor_view_role
ALTER TABLE game_states ADD CONSTRAINT game_states_game_phase_check 
CHECK (game_phase = ANY (ARRAY['discussion'::text, 'voting'::text, 'authority_selection'::text, 'advisor_selection'::text, 'reveal'::text, 'advisor_kill'::text, 'game_over'::text, 'waiting'::text]));
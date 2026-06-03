/*
  # Add Voting System for Authority Selection

  ## Overview
  Players vote to select the Authority for each turn. 
  Players who don't vote before time runs out are counted as blank votes.

  ## Changes

  ### 1. Create votes table
  - `id` (uuid, primary key) - Unique vote identifier
  - `room_id` (uuid, foreign key) - Reference to rooms table
  - `turn_number` (integer) - Turn number for this vote
  - `voter_player_id` (uuid, foreign key) - Player who is voting
  - `voted_for_player_id` (uuid, foreign key, nullable) - Player being voted for (null = blank vote)
  - `created_at` (timestamptz) - Vote timestamp

  ### 2. Update game_states table
  - Update `game_phase` to include 'voting' phase

  ### 3. Add indexes for performance
  - Index on room_id and turn_number for quick vote lookups

  ## Security
  - Enable RLS on votes table
  - Players can only vote once per turn
  - Anyone can view votes (for transparency)
*/

-- Create votes table
CREATE TABLE IF NOT EXISTS votes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  turn_number integer NOT NULL,
  voter_player_id uuid NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  voted_for_player_id uuid REFERENCES players(id) ON DELETE SET NULL,
  created_at timestamptz DEFAULT now(),
  CONSTRAINT unique_vote_per_turn UNIQUE (room_id, turn_number, voter_player_id)
);

-- Create index for faster queries
CREATE INDEX IF NOT EXISTS idx_votes_room_turn ON votes(room_id, turn_number);

-- Enable RLS
ALTER TABLE votes ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Anyone can view votes"
  ON votes FOR SELECT
  TO public
  USING (true);

CREATE POLICY "Players can insert votes"
  ON votes FOR INSERT
  TO public
  WITH CHECK (true);

-- Update game_states phase constraint
ALTER TABLE game_states DROP CONSTRAINT IF EXISTS valid_phase;

ALTER TABLE game_states ADD CONSTRAINT valid_phase 
  CHECK (game_phase IN ('discussion', 'voting', 'authority_selection', 'advisor_selection', 'reveal'));

-- Enable Realtime for votes
ALTER PUBLICATION supabase_realtime ADD TABLE votes;
ALTER TABLE votes REPLICA IDENTITY FULL;
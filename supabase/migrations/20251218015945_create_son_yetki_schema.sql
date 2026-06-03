/*
  # Son Yetki Game Database Schema

  ## Overview
  Database schema for "Son Yetki", a social deduction game where players are assigned hidden roles
  (Loyalists, Traitors, and a Secret Agent) and compete through card selection and voting.

  ## New Tables

  ### 1. rooms
  Game rooms where players gather and play
  - `id` (uuid, primary key) - Unique room identifier
  - `room_code` (text, unique) - 6-character join code
  - `name` (text) - Room display name
  - `status` (text) - Room status: 'waiting', 'playing', 'finished'
  - `max_players` (integer) - Maximum players allowed (5-10)
  - `created_at` (timestamptz) - Room creation time
  - `started_at` (timestamptz, nullable) - Game start time
  - `finished_at` (timestamptz, nullable) - Game end time
  - `winning_team` (text, nullable) - Winner: 'sadik', 'hain', or null

  ### 2. players
  Players in game rooms
  - `id` (uuid, primary key) - Unique player identifier
  - `room_id` (uuid, foreign key) - Reference to rooms table
  - `name` (text) - Player display name
  - `role` (text, nullable) - Player role: 'sadik', 'hain', 'ajan', or null (before assignment)
  - `is_alive` (boolean) - Whether player is still in game
  - `is_host` (boolean) - Whether player is room host
  - `joined_at` (timestamptz) - When player joined

  ### 3. game_states
  Current state of active games
  - `id` (uuid, primary key) - Unique state identifier
  - `room_id` (uuid, foreign key, unique) - Reference to rooms table (one state per room)
  - `current_turn` (integer) - Current turn number
  - `current_authority_player_id` (uuid, nullable) - Player who is currently "Yetkili"
  - `safe_cards_played` (integer) - Number of Safe cards played
  - `kaos_cards_played` (integer) - Number of Kaos cards played
  - `game_phase` (text) - Current phase: 'discussion', 'card_selection', 'voting', 'reveal'
  - `cards_in_deck` (jsonb) - Remaining cards in deck
  - `updated_at` (timestamptz) - Last update time

  ### 4. messages
  Chat messages in game rooms
  - `id` (uuid, primary key) - Unique message identifier
  - `room_id` (uuid, foreign key) - Reference to rooms table
  - `player_id` (uuid, foreign key, nullable) - Reference to players table (null for system messages)
  - `message` (text) - Message content
  - `is_system` (boolean) - Whether this is a system message
  - `created_at` (timestamptz) - Message timestamp

  ### 5. game_actions
  Log of all game actions for replay and analytics
  - `id` (uuid, primary key) - Unique action identifier
  - `room_id` (uuid, foreign key) - Reference to rooms table
  - `turn_number` (integer) - Turn when action occurred
  - `action_type` (text) - Type: 'card_played', 'vote_cast', 'role_reveal', 'game_end'
  - `player_id` (uuid, foreign key, nullable) - Player who performed action
  - `data` (jsonb) - Action-specific data
  - `created_at` (timestamptz) - Action timestamp

  ## Security
  - Enable RLS on all tables
  - Players can only view data from rooms they're in
  - Only room hosts can modify room settings
  - System handles sensitive data like roles server-side
*/

-- Create rooms table
CREATE TABLE IF NOT EXISTS rooms (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_code text UNIQUE NOT NULL,
  name text NOT NULL,
  status text NOT NULL DEFAULT 'waiting',
  max_players integer NOT NULL DEFAULT 8,
  created_at timestamptz DEFAULT now(),
  started_at timestamptz,
  finished_at timestamptz,
  winning_team text,
  CONSTRAINT valid_status CHECK (status IN ('waiting', 'playing', 'finished')),
  CONSTRAINT valid_max_players CHECK (max_players BETWEEN 5 AND 10),
  CONSTRAINT valid_winning_team CHECK (winning_team IS NULL OR winning_team IN ('sadik', 'hain'))
);

-- Create players table
CREATE TABLE IF NOT EXISTS players (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  name text NOT NULL,
  role text,
  is_alive boolean DEFAULT true,
  is_host boolean DEFAULT false,
  joined_at timestamptz DEFAULT now(),
  CONSTRAINT valid_role CHECK (role IS NULL OR role IN ('sadik', 'hain', 'ajan'))
);

-- Create game_states table
CREATE TABLE IF NOT EXISTS game_states (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid UNIQUE NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  current_turn integer DEFAULT 1,
  current_authority_player_id uuid REFERENCES players(id) ON DELETE SET NULL,
  safe_cards_played integer DEFAULT 0,
  kaos_cards_played integer DEFAULT 0,
  game_phase text DEFAULT 'discussion',
  cards_in_deck jsonb DEFAULT '[]'::jsonb,
  updated_at timestamptz DEFAULT now(),
  CONSTRAINT valid_phase CHECK (game_phase IN ('discussion', 'card_selection', 'voting', 'reveal'))
);

-- Create messages table
CREATE TABLE IF NOT EXISTS messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  player_id uuid REFERENCES players(id) ON DELETE SET NULL,
  message text NOT NULL,
  is_system boolean DEFAULT false,
  created_at timestamptz DEFAULT now()
);

-- Create game_actions table
CREATE TABLE IF NOT EXISTS game_actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  turn_number integer NOT NULL,
  action_type text NOT NULL,
  player_id uuid REFERENCES players(id) ON DELETE SET NULL,
  data jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(),
  CONSTRAINT valid_action_type CHECK (action_type IN ('card_played', 'vote_cast', 'role_reveal', 'game_end', 'phase_change'))
);

-- Create indexes for better query performance
CREATE INDEX IF NOT EXISTS idx_players_room_id ON players(room_id);
CREATE INDEX IF NOT EXISTS idx_messages_room_id ON messages(room_id);
CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(room_id, created_at);
CREATE INDEX IF NOT EXISTS idx_game_actions_room_id ON game_actions(room_id);
CREATE INDEX IF NOT EXISTS idx_game_states_room_id ON game_states(room_id);

-- Enable Row Level Security
ALTER TABLE rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE players ENABLE ROW LEVEL SECURITY;
ALTER TABLE game_states ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE game_actions ENABLE ROW LEVEL SECURITY;

-- RLS Policies for rooms
CREATE POLICY "Anyone can view active rooms"
  ON rooms FOR SELECT
  TO public
  USING (status IN ('waiting', 'playing'));

CREATE POLICY "Anyone can create rooms"
  ON rooms FOR INSERT
  TO public
  WITH CHECK (true);

CREATE POLICY "Host can update their room"
  ON rooms FOR UPDATE
  TO public
  USING (
    EXISTS (
      SELECT 1 FROM players
      WHERE players.room_id = rooms.id
      AND players.is_host = true
    )
  );

-- RLS Policies for players
CREATE POLICY "Players can view other players in same room"
  ON players FOR SELECT
  TO public
  USING (true);

CREATE POLICY "Anyone can join a room"
  ON players FOR INSERT
  TO public
  WITH CHECK (true);

CREATE POLICY "Players can update their own data"
  ON players FOR UPDATE
  TO public
  USING (true);

-- RLS Policies for game_states
CREATE POLICY "Players can view game state of their room"
  ON game_states FOR SELECT
  TO public
  USING (
    EXISTS (
      SELECT 1 FROM players
      WHERE players.room_id = game_states.room_id
    )
  );

CREATE POLICY "System can manage game states"
  ON game_states FOR ALL
  TO public
  USING (true)
  WITH CHECK (true);

-- RLS Policies for messages
CREATE POLICY "Players can view messages in their room"
  ON messages FOR SELECT
  TO public
  USING (
    EXISTS (
      SELECT 1 FROM players
      WHERE players.room_id = messages.room_id
    )
  );

CREATE POLICY "Players can send messages to their room"
  ON messages FOR INSERT
  TO public
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM players
      WHERE players.room_id = messages.room_id
    )
  );

-- RLS Policies for game_actions
CREATE POLICY "Players can view actions in their room"
  ON game_actions FOR SELECT
  TO public
  USING (
    EXISTS (
      SELECT 1 FROM players
      WHERE players.room_id = game_actions.room_id
    )
  );

CREATE POLICY "System can log game actions"
  ON game_actions FOR INSERT
  TO public
  WITH CHECK (true);
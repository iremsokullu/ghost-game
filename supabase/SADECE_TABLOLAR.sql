/*
  =============================================================================
  SADECE TABLOLAR — Son Yetki / GHOST veritabanı temel kurulumu
  =============================================================================

  NE ZAMAN KULLANILIR?
  Supabase Table Editor'da rooms, players, game_states, votes, messages
  tabloları görünmüyorsa — ama TEK_SEFERDE_CALISTIR.sql "policy already
  exists" hatası veriyorsa — önce BU dosyayı çalıştırın.

  NASIL KULLANILIR:
  1. Supabase Dashboard → SQL Editor
  2. Bu dosyanın tamamını yapıştırın → Run
  3. Table Editor'ı yenileyin; tablolar görünmeli
  4. Ardından RUN_IN_SUPABASE_SQL_EDITOR.sql dosyasını çalıştırın
     (eksik sütunlar, game_phase kısıtları ve son düzeltmeler için)

  Bu dosya güvenli şekilde tekrar çalıştırılabilir:
  - CREATE TABLE IF NOT EXISTS
  - DROP POLICY IF EXISTS → CREATE POLICY
  =============================================================================
*/

-- =============================================================================
-- TEMEL TABLOLAR (kaynak: 20251218015945_create_son_yetki_schema.sql)
-- =============================================================================

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

CREATE TABLE IF NOT EXISTS game_states (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid UNIQUE NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  current_turn integer DEFAULT 1,
  current_authority_player_id uuid REFERENCES players(id) ON DELETE SET NULL,
  current_advisor_player_id uuid REFERENCES players(id) ON DELETE SET NULL,
  safe_cards_played integer DEFAULT 0,
  kaos_cards_played integer DEFAULT 0,
  game_phase text DEFAULT 'discussion',
  cards_in_deck jsonb DEFAULT '[]'::jsonb,
  selected_cards jsonb DEFAULT '[]'::jsonb,
  advisor_cards jsonb DEFAULT '[]'::jsonb,
  phase_end_time timestamptz,
  consecutive_kaos_count integer DEFAULT 0,
  current_phase_number integer DEFAULT 1,
  last_advisor_id uuid REFERENCES players(id) ON DELETE SET NULL,
  advisor_can_view_role boolean DEFAULT false,
  advisor_can_investigate boolean DEFAULT false,
  viewed_player_id uuid REFERENCES players(id) ON DELETE SET NULL,
  card_peeker_player_id uuid REFERENCES players(id) ON DELETE SET NULL,
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  player_id uuid REFERENCES players(id) ON DELETE SET NULL,
  message text NOT NULL,
  is_system boolean DEFAULT false,
  created_at timestamptz DEFAULT now()
);

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

-- votes (kaynak: 20251218025752_add_voting_system.sql)
CREATE TABLE IF NOT EXISTS votes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  turn_number integer NOT NULL,
  voter_player_id uuid NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  voted_for_player_id uuid REFERENCES players(id) ON DELETE SET NULL,
  created_at timestamptz DEFAULT now(),
  CONSTRAINT unique_vote_per_turn UNIQUE (room_id, turn_number, voter_player_id)
);

-- =============================================================================
-- İNDEKSLER
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_players_room_id ON players(room_id);
CREATE INDEX IF NOT EXISTS idx_messages_room_id ON messages(room_id);
CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(room_id, created_at);
CREATE INDEX IF NOT EXISTS idx_game_actions_room_id ON game_actions(room_id);
CREATE INDEX IF NOT EXISTS idx_game_states_room_id ON game_states(room_id);
CREATE INDEX IF NOT EXISTS idx_votes_room_turn ON votes(room_id, turn_number);

-- =============================================================================
-- REALTIME (tablolar oluşturulduktan sonra — güvenli ekleme)
-- =============================================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'rooms'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE rooms;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'players'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE players;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'game_states'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE game_states;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE messages;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'game_actions'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE game_actions;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'votes'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE votes;
  END IF;
END $$;

ALTER TABLE rooms REPLICA IDENTITY FULL;
ALTER TABLE players REPLICA IDENTITY FULL;
ALTER TABLE game_states REPLICA IDENTITY FULL;
ALTER TABLE messages REPLICA IDENTITY FULL;
ALTER TABLE game_actions REPLICA IDENTITY FULL;
ALTER TABLE votes REPLICA IDENTITY FULL;

-- =============================================================================
-- RLS + DEMO POLİTİKALARI (kaynak: enable_realtime_and_fix_policies + votes)
-- Eski ve yeni politika adlarının tamamı DROP edilir, sonra yeniden oluşturulur.
-- =============================================================================

ALTER TABLE rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE players ENABLE ROW LEVEL SECURITY;
ALTER TABLE game_states ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE game_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE votes ENABLE ROW LEVEL SECURITY;

-- rooms (eski + yeni politika adları)
DROP POLICY IF EXISTS "Anyone can view active rooms" ON rooms;
DROP POLICY IF EXISTS "Anyone can create rooms" ON rooms;
DROP POLICY IF EXISTS "Host can update their room" ON rooms;
DROP POLICY IF EXISTS "Anyone can view rooms" ON rooms;
DROP POLICY IF EXISTS "Anyone can update rooms" ON rooms;

CREATE POLICY "Anyone can view rooms"
  ON rooms FOR SELECT TO public USING (true);
CREATE POLICY "Anyone can create rooms"
  ON rooms FOR INSERT TO public WITH CHECK (true);
CREATE POLICY "Anyone can update rooms"
  ON rooms FOR UPDATE TO public USING (true);

-- players
DROP POLICY IF EXISTS "Players can view other players in same room" ON players;
DROP POLICY IF EXISTS "Anyone can join a room" ON players;
DROP POLICY IF EXISTS "Players can update their own data" ON players;
DROP POLICY IF EXISTS "Anyone can view players" ON players;
DROP POLICY IF EXISTS "Anyone can create players" ON players;
DROP POLICY IF EXISTS "Anyone can update players" ON players;
DROP POLICY IF EXISTS "Anyone can delete players" ON players;

CREATE POLICY "Anyone can view players"
  ON players FOR SELECT TO public USING (true);
CREATE POLICY "Anyone can create players"
  ON players FOR INSERT TO public WITH CHECK (true);
CREATE POLICY "Anyone can update players"
  ON players FOR UPDATE TO public USING (true);
CREATE POLICY "Anyone can delete players"
  ON players FOR DELETE TO public USING (true);

-- game_states
DROP POLICY IF EXISTS "Players can view game state of their room" ON game_states;
DROP POLICY IF EXISTS "System can manage game states" ON game_states;
DROP POLICY IF EXISTS "Anyone can view game states" ON game_states;
DROP POLICY IF EXISTS "Anyone can insert game states" ON game_states;
DROP POLICY IF EXISTS "Anyone can update game states" ON game_states;

CREATE POLICY "Anyone can view game states"
  ON game_states FOR SELECT TO public USING (true);
CREATE POLICY "Anyone can insert game states"
  ON game_states FOR INSERT TO public WITH CHECK (true);
CREATE POLICY "Anyone can update game states"
  ON game_states FOR UPDATE TO public USING (true) WITH CHECK (true);

-- messages
DROP POLICY IF EXISTS "Players can view messages in their room" ON messages;
DROP POLICY IF EXISTS "Players can send messages to their room" ON messages;
DROP POLICY IF EXISTS "Anyone can view messages" ON messages;
DROP POLICY IF EXISTS "Anyone can send messages" ON messages;

CREATE POLICY "Anyone can view messages"
  ON messages FOR SELECT TO public USING (true);
CREATE POLICY "Anyone can send messages"
  ON messages FOR INSERT TO public WITH CHECK (true);

-- game_actions
DROP POLICY IF EXISTS "Players can view actions in their room" ON game_actions;
DROP POLICY IF EXISTS "System can log game actions" ON game_actions;
DROP POLICY IF EXISTS "Anyone can view game actions" ON game_actions;
DROP POLICY IF EXISTS "Anyone can insert game actions" ON game_actions;

CREATE POLICY "Anyone can view game actions"
  ON game_actions FOR SELECT TO public USING (true);
CREATE POLICY "Anyone can insert game actions"
  ON game_actions FOR INSERT TO public WITH CHECK (true);

-- votes
DROP POLICY IF EXISTS "Anyone can view votes" ON votes;
DROP POLICY IF EXISTS "Players can insert votes" ON votes;
DROP POLICY IF EXISTS "Anyone can delete votes" ON votes;

CREATE POLICY "Anyone can view votes"
  ON votes FOR SELECT TO public USING (true);
CREATE POLICY "Players can insert votes"
  ON votes FOR INSERT TO public WITH CHECK (true);
CREATE POLICY "Anyone can delete votes"
  ON votes FOR DELETE TO public USING (true);

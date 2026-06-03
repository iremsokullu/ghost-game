/*
  =============================================================================
  TEK SEFERDE ÇALIŞTIR — GHOST / Son Yetki veritabanı kurulumu
  =============================================================================

  NASIL KULLANILIR:
  1. Tarayıcıda https://supabase.com/dashboard adresine gidin
     (Steam / Valve hesap sayfası DEĞİL — Supabase paneli gerekli)
  2. Projenizi seçin → sol menüden "SQL Editor"
  3. Bu dosyayı açın → Ctrl+A → Ctrl+C (tamamını kopyalayın)
  4. SQL Editor'a yapıştırın → "Run" düğmesine BİR KEZ basın

  Bu dosya 14 migration dosyasını kronolojik sırada + son ek düzeltmeleri
  birleştirir. Ayrı ayrı 14 migration çalıştırmanıza gerek yoktur.

  Yinelenen ifadeler mümkün olduğunca azaltıldı; çakışmalarda son migration
  ve RUN_IN bölümü geçerlidir.
  =============================================================================
*/

-- =============================================================================
-- MIGRATION: 20251218015945_create_son_yetki_schema.sql
-- =============================================================================

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
  safe_cards_played integer DEFAULT 0,
  kaos_cards_played integer DEFAULT 0,
  game_phase text DEFAULT 'discussion',
  cards_in_deck jsonb DEFAULT '[]'::jsonb,
  updated_at timestamptz DEFAULT now(),
  CONSTRAINT valid_phase CHECK (game_phase IN ('discussion', 'card_selection', 'voting', 'reveal'))
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

CREATE INDEX IF NOT EXISTS idx_players_room_id ON players(room_id);
CREATE INDEX IF NOT EXISTS idx_messages_room_id ON messages(room_id);
CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(room_id, created_at);
CREATE INDEX IF NOT EXISTS idx_game_actions_room_id ON game_actions(room_id);
CREATE INDEX IF NOT EXISTS idx_game_states_room_id ON game_states(room_id);

ALTER TABLE rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE players ENABLE ROW LEVEL SECURITY;
ALTER TABLE game_states ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE game_actions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view active rooms" ON rooms FOR SELECT TO public USING (status IN ('waiting', 'playing'));
CREATE POLICY "Anyone can create rooms" ON rooms FOR INSERT TO public WITH CHECK (true);
CREATE POLICY "Host can update their room" ON rooms FOR UPDATE TO public
  USING (EXISTS (SELECT 1 FROM players WHERE players.room_id = rooms.id AND players.is_host = true));
CREATE POLICY "Players can view other players in same room" ON players FOR SELECT TO public USING (true);
CREATE POLICY "Anyone can join a room" ON players FOR INSERT TO public WITH CHECK (true);
CREATE POLICY "Players can update their own data" ON players FOR UPDATE TO public USING (true);
CREATE POLICY "Players can view game state of their room" ON game_states FOR SELECT TO public
  USING (EXISTS (SELECT 1 FROM players WHERE players.room_id = game_states.room_id));
CREATE POLICY "System can manage game states" ON game_states FOR ALL TO public USING (true) WITH CHECK (true);
CREATE POLICY "Players can view messages in their room" ON messages FOR SELECT TO public
  USING (EXISTS (SELECT 1 FROM players WHERE players.room_id = messages.room_id));
CREATE POLICY "Players can send messages to their room" ON messages FOR INSERT TO public
  WITH CHECK (EXISTS (SELECT 1 FROM players WHERE players.room_id = messages.room_id));
CREATE POLICY "Players can view actions in their room" ON game_actions FOR SELECT TO public
  USING (EXISTS (SELECT 1 FROM players WHERE players.room_id = game_actions.room_id));
CREATE POLICY "System can log game actions" ON game_actions FOR INSERT TO public WITH CHECK (true);

-- =============================================================================
-- MIGRATION: 20251218021908_enable_realtime_and_fix_policies.sql
-- =============================================================================

ALTER PUBLICATION supabase_realtime ADD TABLE rooms;
ALTER PUBLICATION supabase_realtime ADD TABLE players;
ALTER PUBLICATION supabase_realtime ADD TABLE game_states;
ALTER PUBLICATION supabase_realtime ADD TABLE messages;
ALTER PUBLICATION supabase_realtime ADD TABLE game_actions;
ALTER TABLE rooms REPLICA IDENTITY FULL;
ALTER TABLE players REPLICA IDENTITY FULL;
ALTER TABLE game_states REPLICA IDENTITY FULL;
ALTER TABLE messages REPLICA IDENTITY FULL;
ALTER TABLE game_actions REPLICA IDENTITY FULL;

DROP POLICY IF EXISTS "Players can view messages in their room" ON messages;
DROP POLICY IF EXISTS "Players can send messages to their room" ON messages;
CREATE POLICY "Anyone can view messages" ON messages FOR SELECT TO public USING (true);
CREATE POLICY "Anyone can send messages" ON messages FOR INSERT TO public WITH CHECK (true);

DROP POLICY IF EXISTS "Players can view other players in same room" ON players;
DROP POLICY IF EXISTS "Anyone can join a room" ON players;
DROP POLICY IF EXISTS "Players can update their own data" ON players;
CREATE POLICY "Anyone can view players" ON players FOR SELECT TO public USING (true);
CREATE POLICY "Anyone can create players" ON players FOR INSERT TO public WITH CHECK (true);
CREATE POLICY "Anyone can update players" ON players FOR UPDATE TO public USING (true);
CREATE POLICY "Anyone can delete players" ON players FOR DELETE TO public USING (true);

DROP POLICY IF EXISTS "Players can view game state of their room" ON game_states;
DROP POLICY IF EXISTS "System can manage game states" ON game_states;
CREATE POLICY "Anyone can view game states" ON game_states FOR SELECT TO public USING (true);
CREATE POLICY "Anyone can insert game states" ON game_states FOR INSERT TO public WITH CHECK (true);
CREATE POLICY "Anyone can update game states" ON game_states FOR UPDATE TO public USING (true);

DROP POLICY IF EXISTS "Anyone can view active rooms" ON rooms;
DROP POLICY IF EXISTS "Anyone can create rooms" ON rooms;
DROP POLICY IF EXISTS "Host can update their room" ON rooms;
CREATE POLICY "Anyone can view rooms" ON rooms FOR SELECT TO public USING (true);
CREATE POLICY "Anyone can create rooms" ON rooms FOR INSERT TO public WITH CHECK (true);
CREATE POLICY "Anyone can update rooms" ON rooms FOR UPDATE TO public USING (true);

DROP POLICY IF EXISTS "Players can view actions in their room" ON game_actions;
DROP POLICY IF EXISTS "System can log game actions" ON game_actions;
CREATE POLICY "Anyone can view game actions" ON game_actions FOR SELECT TO public USING (true);
CREATE POLICY "Anyone can insert game actions" ON game_actions FOR INSERT TO public WITH CHECK (true);


-- =============================================================================
-- MIGRATION: 20251218023149_add_advisor_and_timer_system.sql
-- =============================================================================

ALTER TABLE game_states DROP CONSTRAINT IF EXISTS valid_phase;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'game_states' AND column_name = 'current_advisor_player_id') THEN
    ALTER TABLE game_states ADD COLUMN current_advisor_player_id uuid REFERENCES players(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'game_states' AND column_name = 'phase_end_time') THEN
    ALTER TABLE game_states ADD COLUMN phase_end_time timestamptz;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'game_states' AND column_name = 'selected_cards') THEN
    ALTER TABLE game_states ADD COLUMN selected_cards jsonb DEFAULT '[]'::jsonb;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'game_states' AND column_name = 'advisor_cards') THEN
    ALTER TABLE game_states ADD COLUMN advisor_cards jsonb DEFAULT '[]'::jsonb;
  END IF;
END $$;

ALTER TABLE game_states ADD CONSTRAINT valid_phase 
  CHECK (game_phase IN ('discussion', 'authority_selection', 'advisor_selection', 'reveal'));


-- =============================================================================
-- MIGRATION: 20251218025752_add_voting_system.sql
-- =============================================================================

CREATE TABLE IF NOT EXISTS votes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  turn_number integer NOT NULL,
  voter_player_id uuid NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  voted_for_player_id uuid REFERENCES players(id) ON DELETE SET NULL,
  created_at timestamptz DEFAULT now(),
  CONSTRAINT unique_vote_per_turn UNIQUE (room_id, turn_number, voter_player_id)
);

CREATE INDEX IF NOT EXISTS idx_votes_room_turn ON votes(room_id, turn_number);
ALTER TABLE votes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can view votes" ON votes FOR SELECT TO public USING (true);
CREATE POLICY "Players can insert votes" ON votes FOR INSERT TO public WITH CHECK (true);
ALTER TABLE game_states DROP CONSTRAINT IF EXISTS valid_phase;
ALTER TABLE game_states ADD CONSTRAINT valid_phase 
  CHECK (game_phase IN ('discussion', 'voting', 'authority_selection', 'advisor_selection', 'reveal'));
ALTER PUBLICATION supabase_realtime ADD TABLE votes;
ALTER TABLE votes REPLICA IDENTITY FULL;

-- =============================================================================
-- MIGRATION: 20251218031755_add_special_game_rules.sql
-- =============================================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'game_states' AND column_name = 'consecutive_kaos_count') THEN
    ALTER TABLE game_states ADD COLUMN consecutive_kaos_count integer DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'game_states' AND column_name = 'advisor_can_kill') THEN
    ALTER TABLE game_states ADD COLUMN advisor_can_kill boolean DEFAULT false;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'game_states' AND column_name = 'agent_can_vote') THEN
    ALTER TABLE game_states ADD COLUMN agent_can_vote boolean DEFAULT false;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'game_states' AND column_name = 'current_phase_number') THEN
    ALTER TABLE game_states ADD COLUMN current_phase_number integer DEFAULT 1;
  END IF;
END $$;


-- =============================================================================
-- MIGRATION: 20251218031954_update_game_phase_constraint.sql
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.constraint_column_usage WHERE constraint_name = 'valid_phase' AND table_name = 'game_states') THEN
    ALTER TABLE game_states DROP CONSTRAINT valid_phase;
  END IF;
END $$;

ALTER TABLE game_states ADD CONSTRAINT valid_phase
CHECK (game_phase IN ('discussion', 'voting', 'authority_selection', 'advisor_selection', 'reveal', 'advisor_kill'));


-- =============================================================================
-- MIGRATION: 20251219212001_add_last_advisor_tracking.sql
-- =============================================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'game_states' AND column_name = 'last_advisor_id') THEN
    ALTER TABLE game_states ADD COLUMN last_advisor_id uuid REFERENCES players(id);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'game_states' AND column_name = 'advisor_can_view_role') THEN
    ALTER TABLE game_states ADD COLUMN advisor_can_view_role boolean DEFAULT false;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'game_states' AND column_name = 'viewed_player_id') THEN
    ALTER TABLE game_states ADD COLUMN viewed_player_id uuid REFERENCES players(id);
  END IF;
END $$;


-- =============================================================================
-- MIGRATION: 20251219212240_add_advisor_view_role_phase.sql
-- =============================================================================

ALTER TABLE game_states DROP CONSTRAINT IF EXISTS game_states_game_phase_check;
ALTER TABLE game_states ADD CONSTRAINT game_states_game_phase_check 
CHECK (game_phase IN ('discussion', 'voting', 'authority_selection', 'advisor_selection', 'reveal', 'advisor_kill', 'advisor_view_role'));


-- =============================================================================
-- MIGRATION: 20260113205640_remove_advisor_view_role_phase.sql
-- =============================================================================

UPDATE game_states SET game_phase = 'discussion' WHERE game_phase = 'advisor_view_role';
ALTER TABLE game_states DROP CONSTRAINT IF EXISTS game_states_game_phase_check;
ALTER TABLE game_states ADD CONSTRAINT game_states_game_phase_check 
CHECK (game_phase = ANY (ARRAY['discussion'::text, 'voting'::text, 'authority_selection'::text, 'advisor_selection'::text, 'reveal'::text, 'advisor_kill'::text, 'game_over'::text, 'waiting'::text]));

-- =============================================================================
-- MIGRATION: 20260113211328_rename_advisor_can_kill_to_authority_can_kill.sql
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'game_states' AND column_name = 'advisor_can_kill') THEN
    ALTER TABLE game_states RENAME COLUMN advisor_can_kill TO authority_can_kill;
  END IF;
END $$;


-- =============================================================================
-- MIGRATION: 20260113213043_remove_authority_can_kill_and_agent_can_vote.sql
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'game_states' AND column_name = 'authority_can_kill') THEN
    ALTER TABLE game_states DROP COLUMN authority_can_kill;
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'game_states' AND column_name = 'agent_can_vote') THEN
    ALTER TABLE game_states DROP COLUMN agent_can_vote;
  END IF;
END $$;


-- =============================================================================
-- MIGRATION: 20260523000000_add_card_peek_system.sql
-- =============================================================================

ALTER TABLE game_states DROP CONSTRAINT IF EXISTS valid_phase;
ALTER TABLE game_states DROP CONSTRAINT IF EXISTS game_states_game_phase_check;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'game_states' AND column_name = 'card_peeker_player_id') THEN
    ALTER TABLE game_states ADD COLUMN card_peeker_player_id uuid REFERENCES players(id) ON DELETE SET NULL;
  END IF;
END $$;

ALTER TABLE game_states ADD CONSTRAINT valid_phase
CHECK (game_phase IN (
  'discussion', 'voting', 'authority_selection', 'advisor_selection', 'reveal',
  'card_peek', 'role_peek', 'authority_view_role', 'authority_kill', 'player_kill'
));


-- =============================================================================
-- MIGRATION: 20260523100000_kaos_vote_phases.sql
-- =============================================================================

ALTER TABLE game_states DROP CONSTRAINT IF EXISTS valid_phase;
ALTER TABLE game_states DROP CONSTRAINT IF EXISTS game_states_game_phase_check;

ALTER TABLE game_states ADD CONSTRAINT valid_phase
CHECK (game_phase IN (
  'discussion', 'voting', 'authority_selection', 'advisor_selection', 'reveal',
  'card_peek', 'role_peek', 'authority_view_role', 'authority_kill', 'player_kill'
));


-- =============================================================================
-- MIGRATION: 20260523200000_fix_round2_progression.sql
-- =============================================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'game_states' AND column_name = 'advisor_can_investigate') THEN
    ALTER TABLE game_states ADD COLUMN advisor_can_investigate boolean DEFAULT false;
  END IF;
END $$;

DROP POLICY IF EXISTS "Anyone can delete votes" ON votes;
CREATE POLICY "Anyone can delete votes" ON votes FOR DELETE TO public USING (true);


-- =============================================================================
-- EK DÜZELTMELER (RUN_IN_SUPABASE_SQL_EDITOR.sql — yinelenenler hariç)
-- =============================================================================

UPDATE game_states
SET
  game_phase = 'discussion',
  phase_end_time = now() + interval '60 seconds',
  current_authority_player_id = NULL,
  current_advisor_player_id = NULL,
  advisor_can_view_role = false,
  advisor_can_investigate = false,
  card_peeker_player_id = NULL,
  viewed_player_id = NULL,
  consecutive_kaos_count = 0,
  selected_cards = '[]'::jsonb,
  advisor_cards = '[]'::jsonb
WHERE game_phase = 'reveal'
  AND phase_end_time IS NOT NULL
  AND phase_end_time < now() - interval '15 seconds';

ALTER TABLE game_states DROP CONSTRAINT IF EXISTS valid_phase;
ALTER TABLE game_states DROP CONSTRAINT IF EXISTS game_states_game_phase_check;

ALTER TABLE game_states ADD CONSTRAINT valid_phase
CHECK (game_phase IN (
  'discussion', 'voting', 'authority_selection', 'advisor_selection', 'reveal',
  'card_peek', 'role_peek', 'authority_view_role', 'authority_kill', 'player_kill',
  'advisor_kill', 'game_over', 'waiting'
));

DROP POLICY IF EXISTS "Anyone can update game states" ON game_states;
CREATE POLICY "Anyone can update game states"
  ON game_states FOR UPDATE TO public USING (true) WITH CHECK (true);


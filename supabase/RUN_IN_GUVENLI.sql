/*
  =============================================================================
  GÜVENLİ ÇALIŞTIR — GHOST / Son Yetki (Tur 2+ düzeltmeleri)
  =============================================================================

  NE ZAMAN KULLANILIR?
  - rooms, players, game_states, votes, messages, game_actions tabloları
    ZATEN VAR ama RUN_IN_SUPABASE_SQL_EDITOR.sql veya TEK_SEFERDE_CALISTIR.sql
    hata veriyorsa (ör. "policy already exists", "column already exists")
  - Oyun reveal fazında takılı kalıyorsa
  - Tur 2+ ilerlemiyorsa (advisor_can_investigate, game_phase kısıtları)

  NASIL KULLANILIR:
  1. https://supabase.com/dashboard → projenizi seçin
  2. Sol menü → SQL Editor → New query
  3. Bu dosyanın TAMAMINI kopyalayıp yapıştırın (Ctrl+A → Ctrl+C)
  4. "Run" düğmesine basın
  5. "Success. No rows returned" veya benzeri yeşil onay görmelisiniz
  6. İsterseniz tekrar çalıştırabilirsiniz — güvenlidir (idempotent)

  BU DOSYA NE YAPAR?
  - Eksik game_states sütunlarını ekler (var olanlara dokunmaz)
  - Takılı kalmış reveal satırlarını discussion'a alır
  - game_phase CHECK kısıtını günceller (eski kısıtları önce siler)
  - votes DELETE ve game_states UPDATE politikalarını güvenle oluşturur
  - CREATE TABLE YOK — mevcut tablolarınız korunur

  SIK GÖRÜLEN HATALAR (ESKİ DOSYALARDA):
  ┌─────────────────────────────────────────────────────────────────────────┐
  │ "policy ... already exists"                                             │
  │   → Eski TEK_SEFERDE veya RUN_IN scriptinde DROP POLICY yoktu.          │
  │   → BU DOSYAYI kullanın; DROP POLICY IF EXISTS ile güvenli.             │
  │   → Bu hatayı görürseniz eski scripti bırakın, bu dosyayı çalıştırın.   │
  ├─────────────────────────────────────────────────────────────────────────┤
  │ "column ... already exists"                                             │
  │   → Eski script ALTER TABLE ADD COLUMN doğrudan yapıyordu.              │
  │   → BU DOSYA IF NOT EXISTS ile kontrol eder; sütun varsa atlar.         │
  │   → Bu hatayı görmemelisiniz; görürseniz yine de bu dosyayı deneyin.    │
  ├─────────────────────────────────────────────────────────────────────────┤
  │ "constraint ... already exists" (valid_phase)                           │
  │   → BU DOSYA önce DROP CONSTRAINT IF EXISTS yapar, sonra yeniden ekler. │
  │   → Tekrar çalıştırmak güvenlidir.                                      │
  └─────────────────────────────────────────────────────────────────────────┘

  YOKSAYILACAK / ENDİŞELENMEYİN:
  - "Success. No rows returned" → normal, beklenen sonuç
  - UPDATE 0 rows → takılı reveal yok demektir, sorun değil
  - Script'i ikinci kez çalıştırmak → tamamen güvenli

  TABLOLAR YOKSA:
  Önce SADECE_TABLOLAR.sql dosyasını çalıştırın, sonra bu dosyayı.
  =============================================================================
*/

-- ========== game_states: eksik sütunlar (var olanlara dokunulmaz) ==========
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'game_states' AND column_name = 'current_advisor_player_id'
  ) THEN
    ALTER TABLE game_states ADD COLUMN current_advisor_player_id uuid REFERENCES players(id) ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'game_states' AND column_name = 'selected_cards'
  ) THEN
    ALTER TABLE game_states ADD COLUMN selected_cards jsonb DEFAULT '[]'::jsonb;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'game_states' AND column_name = 'advisor_cards'
  ) THEN
    ALTER TABLE game_states ADD COLUMN advisor_cards jsonb DEFAULT '[]'::jsonb;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'game_states' AND column_name = 'advisor_can_investigate'
  ) THEN
    ALTER TABLE game_states ADD COLUMN advisor_can_investigate boolean DEFAULT false;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'game_states' AND column_name = 'card_peeker_player_id'
  ) THEN
    ALTER TABLE game_states ADD COLUMN card_peeker_player_id uuid REFERENCES players(id) ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'game_states' AND column_name = 'consecutive_kaos_count'
  ) THEN
    ALTER TABLE game_states ADD COLUMN consecutive_kaos_count integer DEFAULT 0;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'game_states' AND column_name = 'advisor_can_view_role'
  ) THEN
    ALTER TABLE game_states ADD COLUMN advisor_can_view_role boolean DEFAULT false;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'game_states' AND column_name = 'viewed_player_id'
  ) THEN
    ALTER TABLE game_states ADD COLUMN viewed_player_id uuid REFERENCES players(id) ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'game_states' AND column_name = 'last_advisor_id'
  ) THEN
    ALTER TABLE game_states ADD COLUMN last_advisor_id uuid REFERENCES players(id) ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'game_states' AND column_name = 'current_phase_number'
  ) THEN
    ALTER TABLE game_states ADD COLUMN current_phase_number integer DEFAULT 1;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'game_states' AND column_name = 'phase_end_time'
  ) THEN
    ALTER TABLE game_states ADD COLUMN phase_end_time timestamptz;
  END IF;
END $$;

-- ========== takılı kalmış reveal → discussion (acil kurtarma) ==========
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

-- ========== game_phase: eski kısıtları sil, güncel listeyi ekle ==========
ALTER TABLE game_states DROP CONSTRAINT IF EXISTS valid_phase;
ALTER TABLE game_states DROP CONSTRAINT IF EXISTS game_states_game_phase_check;

ALTER TABLE game_states ADD CONSTRAINT valid_phase
CHECK (game_phase IN (
  'discussion',
  'voting',
  'authority_selection',
  'advisor_selection',
  'reveal',
  'card_peek',
  'role_peek',
  'authority_view_role',
  'authority_kill',
  'player_kill',
  'advisor_kill',
  'game_over',
  'waiting'
));

-- ========== votes: Kaos sonrası oyları silmek için DELETE politikası ==========
DROP POLICY IF EXISTS "Anyone can delete votes" ON votes;
CREATE POLICY "Anyone can delete votes"
  ON votes FOR DELETE
  TO public
  USING (true);

-- ========== game_states: UPDATE WITH CHECK (RLS engeli önleme) ==========
DROP POLICY IF EXISTS "Anyone can update game states" ON game_states;
CREATE POLICY "Anyone can update game states"
  ON game_states FOR UPDATE
  TO public
  USING (true)
  WITH CHECK (true);

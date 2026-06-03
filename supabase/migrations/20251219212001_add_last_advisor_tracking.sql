/*
  # Son Danışman Takibi ve Rol Görme Özelliği

  1. Değişiklikler
    - `game_states` tablosuna `last_advisor_id` sütunu eklendi
      - Ard arda aynı kişiye yetki verilmemesi için son danışmanı takip eder
    - `game_states` tablosuna `advisor_can_view_role` boolean sütunu eklendi
      - 2. kaos kartı çıktığında danışmanın rol görme yetkisi olup olmadığını belirler
    - `game_states` tablosuna `viewed_player_id` sütunu eklendi
      - Danışmanın hangi oyuncunun rolünü gördüğünü takip eder
  
  2. Güvenlik
    - Mevcut RLS politikaları geçerli
*/

-- last_advisor_id sütununu ekle
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'game_states' AND column_name = 'last_advisor_id'
  ) THEN
    ALTER TABLE game_states ADD COLUMN last_advisor_id uuid REFERENCES players(id);
  END IF;
END $$;

-- advisor_can_view_role sütununu ekle
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'game_states' AND column_name = 'advisor_can_view_role'
  ) THEN
    ALTER TABLE game_states ADD COLUMN advisor_can_view_role boolean DEFAULT false;
  END IF;
END $$;

-- viewed_player_id sütununu ekle
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'game_states' AND column_name = 'viewed_player_id'
  ) THEN
    ALTER TABLE game_states ADD COLUMN viewed_player_id uuid REFERENCES players(id);
  END IF;
END $$;
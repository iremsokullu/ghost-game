/*
  # Tur 2+ ilerleme düzeltmeleri

  - advisor_can_investigate: 3. ardışık Kaos öldürme oylaması bayrağı (kodda kullanılıyordu, sütun yoktu)
  - votes DELETE: Kaos sonrası oyları temizlemek için gerekli
*/

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'game_states' AND column_name = 'advisor_can_investigate'
  ) THEN
    ALTER TABLE game_states ADD COLUMN advisor_can_investigate boolean DEFAULT false;
  END IF;
END $$;

DROP POLICY IF EXISTS "Anyone can delete votes" ON votes;
CREATE POLICY "Anyone can delete votes"
  ON votes FOR DELETE
  TO public
  USING (true);

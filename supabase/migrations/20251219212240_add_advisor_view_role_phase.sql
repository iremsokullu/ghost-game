/*
  # Advisor View Role Phase Ekleme

  1. Değişiklikler
    - game_states tablosundaki game_phase constraint'ine 'advisor_view_role' fazı eklendi
      - 2. kaos kartında danışmanın rol görme fazı için
  
  2. Güvenlik
    - Mevcut RLS politikaları geçerli
*/

-- Önce eski constraint'i kaldır
ALTER TABLE game_states DROP CONSTRAINT IF EXISTS game_states_game_phase_check;

-- Yeni constraint'i ekle
ALTER TABLE game_states ADD CONSTRAINT game_states_game_phase_check 
CHECK (game_phase IN ('discussion', 'voting', 'authority_selection', 'advisor_selection', 'reveal', 'advisor_kill', 'advisor_view_role'));
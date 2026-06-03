# Tur 2 takılması — ne yanlıştı, ne yaptık

## Asıl hata (kök neden)

Oyun **reveal** fazından **discussion** (Tur 2) fazına geçerken `game_states` satırı güncellenmeli. Güncelleme şu yüzdenlerle **sessizce başarısız** oluyordu:

1. **Eksik sütun `advisor_can_investigate`** — Kod `nextTurn` içinde bu alanı da yazıyor; Supabase’de sütun yoksa tüm UPDATE reddedilir, faz `reveal`’de kalır.
2. **PhaseTimer tek seferlik timeout** — Süre dolunca `timeout` bir kez tetikleniyordu; DB hatası olunca **bir daha denemiyordu**.
3. **Yarış / kilit** — Bir istemci `phaseAdvanceInFlight` ile ilerlerken diğeri duruyor; başarısız denemeden sonra faz değişmediği için watch yeniden tetiklenmiyordu.
4. **Eski `game_states_game_phase_check`** — Bazı kurulumlarda `role_peek` / `player_kill` izinli değil (ardışık Kaos yolları); reveal→discussion genelde izinlidir ama çift constraint karışıklığı olabiliyor.

Hata sadece `console.error`’daydı; oyuncu ekranda “Kart açıldı, otomatik geçecek” görüp **Tur 1 / reveal**’de kalıyordu.

## Yapılan kod düzeltmeleri

- `updateGameState`: eksik sütun hatasında opsiyonel alanları düşürüp yeniden dener; hata **üst snackbar**’da gösterilir.
- `nextTurn`: önce tam patch, olmazsa çekirdek patch; 10 sn reveal takılınca faz korumasız zorla ilerleme.
- `syncPhaseIfExpired`: her 2 sn kontrol + reveal 10 sn aşımında `advanceFromReveal(true)`.
- `PhaseTimer`: süre dolduktan sonra her **3 sn**’de timeout’u yeniden dener.

## Supabase’de yapmanız gereken (zorunlu)

1. [Supabase Dashboard](https://supabase.com/dashboard) → projeniz → **SQL Editor**
2. `supabase/RUN_IN_SUPABASE_SQL_EDITOR.sql` dosyasının **tamamını** yapıştırıp **Run**
3. Hata yoksa: mevcut takılı odalar için reveal > 15 sn olan kayıtlar otomatik tartışmaya alınır

### Hızlı doğrulama (SQL Editor)

```sql
SELECT column_name
FROM information_schema.columns
WHERE table_name = 'game_states'
  AND column_name IN ('advisor_can_investigate', 'card_peeker_player_id', 'consecutive_kaos_count');
```

Üç satır da gelmeli.

## Test adımları

1. `npm run dev` ile istemciyi yenileyin (Ctrl+F5).
2. 5+ oyuncu ile oda açın, oyunu başlatın.
3. Tur 1: tartışma → oylama → yetkili/danışan kart → **reveal** (5 sn).
4. Bekleyin veya hiç dokunmayın — **Tur 2** tartışması ve üstte **Tur 2** yazısı gelmeli.
5. Kırmızı snackbar çıkarsa mesajı kopyalayın; büyük ihtimalle SQL dosyası çalışmamıştır.

## Hâlâ takılırsa

SQL Editor’da (oda `room_id`’nizi biliyorsanız):

```sql
UPDATE game_states
SET game_phase = 'discussion',
    phase_end_time = now() + interval '60 seconds',
    current_turn = current_turn + 1
WHERE room_id = 'ODA-UUID-BURAYA'
  AND game_phase = 'reveal';
```

Ardından sayfayı yenileyin.

# GHOST oyunu — Supabase kurulumu (basit)

Bolt’tan indirdiğiniz projede oyun **sizin kendi Supabase hesabınıza** bağlanmalıdır. Bolt’un sunduğu demo ortamındaki veritabanı sizin değildir; gerçek oda ve oyuncular için ücretsiz Supabase hesabı açın.

---

## 1. Supabase hesabı ve proje

1. Tarayıcıda [https://supabase.com](https://supabase.com) adresine gidin.
2. **Sign up** ile ücretsiz kayıt olun (Google ile de olur).
3. **New Project** → proje adı, veritabanı şifresi (bir yere not edin), bölge (region) seçin → **Create**.

Projenin hazır olması birkaç dakika sürebilir.

---

## 2. API bilgilerini kopyalayın

1. Sol menüden **Project Settings** (dişli) → **API**.
2. Şunları kopyalayın:
   - **Project URL** (örnek: `https://xxxxx.supabase.co`)
   - **anon public** anahtar (uzun metin; `service_role` değil)

---

## 3. Bilgisayarınızda `.env.local` dosyası

Proje klasörü: `c:\Users\sokul\OneDrive\Masaüstü\project`

1. Bu klasörde `.env.example` dosyasına bakın (şablon).
2. Aynı klasörde yeni dosya: **`.env.local`** (nokta ile başlar).
3. İçine şunu yazın (kendi değerlerinizle):

```
VITE_SUPABASE_URL=https://SIZIN_PROJE.supabase.co
VITE_SUPABASE_ANON_KEY=sizin_anon_public_anahtariniz
```

**Önemli:** `.env.local` dosyasını kimseyle paylaşmayın; Git’e eklemeyin (projede zaten gizli tutulur).

Eski **`.env`** dosyası Bolt demo’sundan kalma olabilir. Kendi Supabase bilgilerinizi **`.env.local`** içine yazın; Vite önce `.env.local` değerlerini kullanır.

---

## 4. Veritabanı tabloları (SQL)

Supabase panelinde sol menü → **SQL** → **SQL Editor**.

### A) Yeni, boş proje (ilk kez kuruyorsanız)

Önce `supabase\migrations` klasöründeki dosyaları **aşağıdaki sırayla**, her birinin **tüm içeriğini** kopyalayıp SQL Editor’da **Run** ile çalıştırın:

| Sıra | Dosya |
|------|--------|
| 1 | `20251218015945_create_son_yetki_schema.sql` |
| 2 | `20251218021908_enable_realtime_and_fix_policies.sql` |
| 3 | `20251218023149_add_advisor_and_timer_system.sql` |
| 4 | `20251218025752_add_voting_system.sql` |
| 5 | `20251218031755_add_special_game_rules.sql` |
| 6 | `20251218031954_update_game_phase_constraint.sql` |
| 7 | `20251219212001_add_last_advisor_tracking.sql` |
| 8 | `20251219212240_add_advisor_view_role_phase.sql` |
| 9 | `20260113205640_remove_advisor_view_role_phase.sql` |
| 10 | `20260113211328_rename_advisor_can_kill_to_authority_can_kill.sql` |
| 11 | `20260113213043_remove_authority_can_kill_and_agent_can_vote.sql` |
| 12 | `20260523000000_add_card_peek_system.sql` |
| 13 | `20260523100000_kaos_vote_phases.sql` |
| 14 | `20260523200000_fix_round2_progression.sql` |

Tam yol örneği:  
`c:\Users\sokul\OneDrive\Masaüstü\project\supabase\migrations\20251218015945_create_son_yetki_schema.sql`

### B) Son adım (her zaman)

Dosyanın **tamamını** bir kez çalıştırın:

`c:\Users\sokul\OneDrive\Masaüstü\project\supabase\RUN_IN_SUPABASE_SQL_EDITOR.sql`

Bu dosya Tur 2+ düzeltmeleri ve güncel oyun fazlarını tamamlar. Tablolar yoksa önce **A** adımını yapın.

---

## 5. Oyunu çalıştırın

Proje klasöründe terminal (PowerShell):

```bash
npm run dev
```

Daha önce çalışıyorsa durdurup (**Ctrl+C**) tekrar `npm run dev` yazın — `.env.local` okunması için gerekir.

Tarayıcıda açılan adresten odayı oluşturup test edin.

---

## Sorun giderme (kısa)

| Belirti | Ne yapın |
|--------|----------|
| “Missing Supabase environment variables” | `.env.local` var mı, iki satır doğru mu, `npm run dev` yeniden mi |
| Oda açılmıyor / hata | SQL adımlarını sırayla tekrar kontrol edin |
| Eski Bolt demo’su | Kendi URL ve anon key kullanın; başkasının projesine bağlanmayın |

---

## Özet

- **Ücretsiz** Supabase → kendi projeniz → API URL + anon key  
- **`.env.local`** → sadece sizde, gerçek anahtarlar  
- **SQL** → migrations sırası → sonra `RUN_IN_SUPABASE_SQL_EDITOR.sql`  
- **`npm run dev`** → yeniden başlat  

İyi oyunlar.

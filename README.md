# Son Yetki - Sosyal Çıkarım Oyunu

Tarayıcı tabanlı çok oyunculu sosyal çıkarım oyunu. Oyuncular gizli roller alır ve kartlar üzerinden stratejik kararlar vererek takımlarını zafere taşımaya çalışır.

## Oyun Hakkında

Son Yetki, oyunculara gizli roller dağıtılan bir sosyal çıkarım oyunudur:
- **Sadıklar**: Safe kartlarını oynamaya çalışır
- **Hainler**: Kaos kartlarını oynamaya çalışır
- **Gizli Ajan**: Kimliğini gizleyerek doğru anda harekete geçer

### Kazanma Koşulları
- **Sadıklar kazanır**: 5 Safe kart oynanırsa
- **Hainler kazanır**: 6 Kaos kart oynanırsa

## Teknolojiler

- **Frontend**: Vue 3 + TypeScript + Vuetify
- **Backend**: Supabase (PostgreSQL + Realtime)
- **Geliştirme**: Vite

## Özellikler

- Oda oluşturma ve katılma sistemi
- 5-10 oyuncu desteği
- Gerçek zamanlı sohbet
- Otomatik rol dağıtımı
- Tur bazlı Yetkili ve Danışan sistemi
- Zamanlı fazlar (Tartışma, Yetkili Seçimi, Danışan Seçimi)
- Gerçek zamanlı oyun senkronizasyonu
- Responsive tasarım

## Kurulum

1. Bağımlılıkları yükleyin:
```bash
npm install
```

2. Uygulamayı başlatın:
```bash
npm run dev
```

3. Projeyi derleyin:
```bash
npm run build
```

## Nasıl Oynanır

1. **Ana Sayfa**: İsminizi girin
2. **Oda Oluştur**: Yeni bir oyun odası açın veya mevcut bir odaya katılın
3. **Oyunu Başlat**: Host olarak minimum 5 oyuncuyla oyunu başlatın
4. **Oyun Akışı**:
   - **Tartışma Fazı (60 sn)**: Yetkili ve Danışan belirlenir, oyuncular tartışır
   - **Yetkili Seçimi (30 sn)**: Yetkili desteden 3 kart çeker, birini gömer, kalan 2'sini Danışana verir
   - **Danışan Seçimi (30 sn)**: Danışan aldığı 2 karttan birini gömer, diğerini oyuna açar
   - **Açılış (5 sn)**: Açılan kart skora eklenir ve bir sonraki tura geçilir
5. **Kazan**: İlk takım hedefine ulaşan kazanır (5 Safe veya 6 Kaos kart)

## Proje Yapısı

```
src/
├── components/       # Vue bileşenleri
│   ├── ChatPanel.vue        # Gerçek zamanlı sohbet
│   ├── PlayersList.vue      # Oyuncu listesi ve rol gösterimi
│   └── PhaseTimer.vue       # Faz zamanlayıcısı
├── views/           # Sayfa görünümleri
│   ├── HomePage.vue         # Ana sayfa ve oda listesi
│   └── GameRoom.vue         # Oyun odası
├── lib/             # Supabase client yapılandırması
├── plugins/         # Vuetify yapılandırması
└── router/          # Vue Router yapılandırması

supabase/
└── migrations/      # Veritabanı migrasyonları
    ├── create_son_yetki_schema.sql
    ├── enable_realtime_and_fix_policies.sql
    └── add_advisor_and_timer_system.sql
```

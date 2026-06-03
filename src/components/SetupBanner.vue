<script setup lang="ts">
import { supabaseConfigError, showSupabaseSetupBanner } from '../lib/supabase'
</script>

<template>
  <v-alert
    v-if="showSupabaseSetupBanner"
    type="warning"
    variant="tonal"
    border="start"
    class="setup-banner"
  >
    <div class="setup-title">Supabase ayarlı değil — oyun online çalışmaz.</div>
    <div class="setup-text">
      {{ supabaseConfigError }}
    </div>
    <div class="setup-text">
      Proje kökünde <code>.env.local</code> oluşturun (Vite bunu otomatik okur):
      <div class="setup-code">
        <div><code>VITE_SUPABASE_URL=...</code></div>
        <div><code>VITE_SUPABASE_ANON_KEY=...</code></div>
      </div>
      Kaydettikten sonra geliştirme sunucusunu durdurup (<kbd>Ctrl+C</kbd>) tekrar <code>npm run dev</code> çalıştırın.
    </div>
  </v-alert>
</template>

<style scoped>
.setup-banner {
  margin-bottom: 10px;
}
.setup-title {
  font-weight: 800;
  margin-bottom: 4px;
}
.setup-text {
  font-size: 0.9rem;
  opacity: 0.9;
}
.setup-code {
  margin-top: 6px;
  opacity: 0.95;
}
</style>

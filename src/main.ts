import { createApp } from 'vue'
import './style.css'
import App from './App.vue'
import vuetify from './plugins/vuetify'
import router from './router'
import { verifySupabaseConnection } from './lib/supabase'

void verifySupabaseConnection()

createApp(App)
  .use(vuetify)
  .use(router)
  .mount('#app')

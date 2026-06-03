import 'vuetify/styles'
import { createVuetify } from 'vuetify'
import * as components from 'vuetify/components'
import * as directives from 'vuetify/directives'
import '@mdi/font/css/materialdesignicons.css'

export default createVuetify({
  components,
  directives,
  theme: {
    defaultTheme: 'dark',
    themes: {
      dark: {
        dark: true,
        colors: {
          background: '#0A0E27',
          surface: '#151B3D',
          primary: '#0D47A1',
          secondary: '#00838F',
          accent: '#FF6B35',
          error: '#D32F2F',
          warning: '#FFA726',
          info: '#00ACC1',
          success: '#43A047',
          safe: '#2E7D32',
          kaos: '#C62828',
          sadik: '#43A047',
          hain: '#C62828',
          ajan: '#C62828',
        },
      },
      light: {
        dark: false,
        colors: {
          background: '#F5F7FA',
          surface: '#FFFFFF',
          primary: '#1565C0',
          secondary: '#00838F',
          accent: '#FF6B35',
          error: '#D32F2F',
          warning: '#F57C00',
          info: '#0288D1',
          success: '#43A047',
          safe: '#2E7D32',
          kaos: '#C62828',
          sadik: '#43A047',
          hain: '#C62828',
          ajan: '#C62828',
        },
      },
    },
  },
})

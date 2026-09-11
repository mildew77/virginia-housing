import { createApp } from 'vue'
import 'leaflet/dist/leaflet.css'
import './styles.css'
import App from './App.vue'

createApp(App).mount('#app')

if (import.meta.env.PROD) {
  fetch('/api/visit', { method: 'POST', keepalive: true }).catch(() => {})
}

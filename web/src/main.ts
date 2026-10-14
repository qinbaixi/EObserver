import { createApp } from 'vue'
import { createPinia } from 'pinia'
import App from './App.vue'
import { router } from './router'
import { i18n } from './i18n'
import { client } from './api/ws'
import './style.css'

client.connect()
createApp(App).use(createPinia()).use(router).use(i18n).mount('#app')

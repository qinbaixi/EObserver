import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// The build goes straight into the Erlang app's priv dir so a release
// serves it without any Node runtime.
export default defineConfig({
  plugins: [vue()],
  build: {
    outDir: '../apps/eobserver/priv/www',
    emptyOutDir: true,
    chunkSizeWarningLimit: 1500,
  },
  server: {
    proxy: {
      '/ws': { target: 'ws://localhost:8090', ws: true },
    },
  },
})

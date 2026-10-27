import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// The build goes straight into the Erlang app's priv dir so a release
// serves it without any Node runtime.
export default defineConfig({
  plugins: [vue()],
  define: {
    __VUE_I18N_FULL_INSTALL__: true,
    __VUE_I18N_LEGACY_API__: false,
    __INTLIFY_PROD_DEVTOOLS__: false,
  },
  build: {
    outDir: '../apps/eobserver/priv/www',
    emptyOutDir: true,
    chunkSizeWarningLimit: 1500,
    // The BEAM Book's images are only shown in the reader and cards; keep
    // them out of the main bundle even when small.
    assetsInlineLimit: (file: string) => (file.includes('/beambook/data/img/') ? false : undefined),
  },
  server: {
    proxy: {
      '/ws': { target: 'ws://localhost:8090', ws: true },
    },
  },
})

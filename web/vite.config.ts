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
    // them out of the main bundle even when small (both POSIX and Windows paths).
    assetsInlineLimit: (file: string) => (/[\\/]beambook[\\/]data[\\/]img[\\/]/.test(file) ? false : undefined),
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (id.includes('node_modules/echarts') || id.includes('node_modules/zrender') || id.includes('node_modules/vue-echarts')) {
            return 'echarts'
          }
          if (id.includes('node_modules/naive-ui') || id.includes('node_modules/vueuc') || id.includes('node_modules/@css-render')) {
            return 'naive-ui'
          }
          if (id.includes('node_modules/vue') || id.includes('node_modules/pinia') || id.includes('node_modules/@intlify')) {
            return 'vue-vendor'
          }
          return undefined
        },
      },
    },
  },
  server: {
    proxy: {
      '/ws': { target: 'ws://localhost:8090', ws: true },
    },
  },
})

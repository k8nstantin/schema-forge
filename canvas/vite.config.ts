import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// `npm run dev` serves the canvas with hot reload, its /api calls going to a running `schema-forge serve`.
export default defineConfig({
  plugins: [react()],
  server: { proxy: { '/api': 'http://127.0.0.1:7410' } },
  build: { outDir: 'dist', emptyOutDir: true, chunkSizeWarningLimit: 4000 },
})

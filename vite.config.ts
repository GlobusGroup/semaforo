import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { azioniApiPlugin } from './server/azioniPlugin.ts'

export default defineConfig({
  plugins: [react(), azioniApiPlugin()],
  server: {
    host: '127.0.0.1',
    port: 3106,
    strictPort: true,
    allowedHosts: ['azioni.test'],
  },
})

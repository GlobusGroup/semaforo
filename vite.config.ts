import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { semaforoApiPlugin } from './server/semaforoPlugin.ts'

export default defineConfig({
  plugins: [react(), semaforoApiPlugin()],
  server: {
    host: '127.0.0.1',
    port: 3106,
    strictPort: true,
    allowedHosts: ['azioni.test'],
  },
})

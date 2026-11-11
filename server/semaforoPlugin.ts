import type { Connect, Plugin } from 'vite'
import { RunStore } from './runStore.ts'

export function semaforoApiPlugin(): Plugin {
  const store = new RunStore()

  const handler: Connect.NextHandleFunction = async (req, res, next) => {
    if (req.method !== 'GET') {
      next()
      return
    }

    const force = new URL(req.url ?? '/', 'http://local').searchParams.has('force')

    try {
      const payload = await store.snapshot(force)
      res.setHeader('Content-Type', 'application/json; charset=utf-8')
      res.setHeader('Cache-Control', 'no-store')
      res.end(JSON.stringify(payload))
    } catch (err) {
      const message = (err as Error).message || 'Failed to fetch workflow runs'
      console.error('[semaforo]', message)
      res.statusCode = 502
      res.setHeader('Content-Type', 'application/json; charset=utf-8')
      res.end(JSON.stringify({ error: 'Unable to load GitHub Actions', detail: message }))
    }
  }

  return {
    name: 'semaforo-api',
    configureServer(server) {
      server.middlewares.use('/api/runs', handler)
    },
    configurePreviewServer(server) {
      server.middlewares.use('/api/runs', handler)
    },
  }
}

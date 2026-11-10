import { useCallback, useEffect, useRef, useState } from 'react'
import type { ApiErrorBody, RunsResponse } from '../types'

export const POLL_MS = 20_000

export interface UseRunsState {
  data: RunsResponse | null
  error: string | null
  detail: string | null
  loading: boolean
  refreshing: boolean
  refresh: () => void
}

export function useRuns(): UseRunsState {
  const [data, setData] = useState<RunsResponse | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [detail, setDetail] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const abortRef = useRef<AbortController | null>(null)
  const hasData = useRef(false)

  const load = useCallback(async (force = false) => {
    // Polls never stack: the server shares one scan anyway, so wait for it.
    if (abortRef.current && !force) return
    abortRef.current?.abort()
    const controller = new AbortController()
    abortRef.current = controller

    if (hasData.current) setRefreshing(true)
    else setLoading(true)

    try {
      const res = await fetch(force ? '/api/runs?force=1' : '/api/runs', { signal: controller.signal })
      if (!res.ok) {
        const body = (await res.json().catch(() => null)) as ApiErrorBody | null
        throw new Error(body?.detail || body?.error || `HTTP ${res.status}`)
      }
      const payload = (await res.json()) as RunsResponse
      setData(payload)
      setError(null)
      setDetail(null)
      hasData.current = true
    } catch (err) {
      if ((err as Error).name === 'AbortError') return
      setError('Unable to load GitHub Actions')
      setDetail((err as Error).message)
    } finally {
      if (abortRef.current === controller) abortRef.current = null
      if (!controller.signal.aborted) {
        setLoading(false)
        setRefreshing(false)
      }
    }
  }, [])

  useEffect(() => {
    void load()
    const id = window.setInterval(() => void load(), POLL_MS)
    return () => {
      window.clearInterval(id)
      abortRef.current?.abort()
      abortRef.current = null
    }
  }, [load])

  return { data, error, detail, loading, refreshing, refresh: () => void load(true) }
}

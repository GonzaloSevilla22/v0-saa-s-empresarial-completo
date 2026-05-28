"use client"

import { useCallback, useRef, useState } from "react"

/**
 * Durable idempotency key for a create-operation form.
 *
 * Lifecycle (see anti-duplicate architecture, idempotency §5):
 *   - Generated once when the form mounts.
 *   - Persisted in sessionStorage under `scope` so an F5 / accidental reload of
 *     the SAME tab reuses the SAME key — a resubmit after a lost response then
 *     hits the server's replay branch instead of creating a duplicate.
 *   - reset() must be called on a SUCCESSFUL submit so the NEXT operation gets a
 *     fresh key. A key that outlives its operation would make the next, genuinely
 *     different operation replay the previous one (a lost sale) — so resetting on
 *     success is mandatory, not optional.
 *
 * sessionStorage (not localStorage) is deliberate: it is per-tab, so two tabs get
 * two independent keys (two distinct intents, correctly allowed). Cross-tab
 * duplicate *intent* is a UX concern, not an idempotency one.
 */
export function useIdempotencyKey(scope: string) {
  const storageKey = `idem:${scope}`

  const read = useCallback((): string => {
    if (typeof window === "undefined") return crypto.randomUUID()
    const existing = window.sessionStorage.getItem(storageKey)
    if (existing) return existing
    const fresh = crypto.randomUUID()
    window.sessionStorage.setItem(storageKey, fresh)
    return fresh
  }, [storageKey])

  const [key, setKey] = useState<string>(read)
  const keyRef = useRef(key)
  keyRef.current = key

  const reset = useCallback(() => {
    const fresh = crypto.randomUUID()
    if (typeof window !== "undefined") {
      window.sessionStorage.setItem(storageKey, fresh)
    }
    keyRef.current = fresh
    setKey(fresh)
  }, [storageKey])

  return { idempotencyKey: key, resetIdempotencyKey: reset }
}

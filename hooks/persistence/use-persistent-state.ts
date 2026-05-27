"use client"

import { useCallback, useEffect, useState } from "react"

type StorageBackend = "localStorage" | "sessionStorage" | "cookie"

interface PersistentStateOptions<T> {
  backend?: StorageBackend
  /** Cookie max-age in seconds. Default: 1 year */
  cookieMaxAge?: number
  serializer?: {
    serialize: (value: T) => string
    deserialize: (raw: string) => T
  }
}

const DEFAULT_SERIALIZER = {
  serialize: JSON.stringify,
  deserialize: JSON.parse,
}

function readFromStorage<T>(
  key: string,
  backend: StorageBackend,
  deserialize: (raw: string) => T,
): T | null {
  try {
    if (backend === "cookie") {
      const match = document.cookie
        .split("; ")
        .find((c) => c.startsWith(`${key}=`))
      if (!match) return null
      return deserialize(decodeURIComponent(match.split("=")[1]))
    }

    const store =
      backend === "sessionStorage" ? sessionStorage : localStorage
    const raw = store.getItem(key)
    if (raw === null) return null
    return deserialize(raw)
  } catch {
    return null
  }
}

function writeToStorage<T>(
  key: string,
  value: T,
  backend: StorageBackend,
  serialize: (value: T) => string,
  cookieMaxAge: number,
): void {
  try {
    if (backend === "cookie") {
      const encoded = encodeURIComponent(serialize(value))
      const secure = location.protocol === "https:" ? "; Secure" : ""
      document.cookie = `${key}=${encoded}; path=/; max-age=${cookieMaxAge}; SameSite=Lax${secure}`
      return
    }
    const store =
      backend === "sessionStorage" ? sessionStorage : localStorage
    store.setItem(key, serialize(value))
  } catch {
    // Storage full or private mode — degrade silently
  }
}

function removeFromStorage(key: string, backend: StorageBackend): void {
  try {
    if (backend === "cookie") {
      document.cookie = `${key}=; path=/; max-age=0`
      return
    }
    const store =
      backend === "sessionStorage" ? sessionStorage : localStorage
    store.removeItem(key)
  } catch {
    // ignore
  }
}

/**
 * Hybrid persistent state. Works like useState but syncs to the chosen
 * storage backend. SSR-safe: renders with `initialValue` on the server,
 * hydrates from storage on the client after mount.
 *
 * @example
 * // Persist sidebar state in a cookie (accessible server-side)
 * const [open, setOpen, clearOpen] = usePersistentState("ui:sidebar", true, {
 *   backend: "cookie",
 * })
 *
 * // Persist table filters in localStorage
 * const [filters, setFilters] = usePersistentState("filters:productos", defaultFilters, {
 *   backend: "localStorage",
 * })
 */
export function usePersistentState<T>(
  key: string,
  initialValue: T,
  options: PersistentStateOptions<T> = {},
): [T, (value: T | ((prev: T) => T)) => void, () => void] {
  const {
    backend = "localStorage",
    cookieMaxAge = 60 * 60 * 24 * 365,
    serializer = DEFAULT_SERIALIZER as typeof DEFAULT_SERIALIZER & {
      serialize: (v: T) => string
      deserialize: (r: string) => T
    },
  } = options

  // SSR: always start with initialValue to prevent hydration mismatch
  const [state, setState] = useState<T>(initialValue)

  // After mount, hydrate from storage
  useEffect(() => {
    const persisted = readFromStorage<T>(key, backend, serializer.deserialize)
    if (persisted !== null) setState(persisted)
  }, [key, backend, serializer.deserialize])

  const setValue = useCallback(
    (value: T | ((prev: T) => T)) => {
      setState((prev) => {
        const next = typeof value === "function"
          ? (value as (prev: T) => T)(prev)
          : value
        writeToStorage(key, next, backend, serializer.serialize, cookieMaxAge)
        return next
      })
    },
    [key, backend, serializer.serialize, cookieMaxAge],
  )

  const clearValue = useCallback(() => {
    removeFromStorage(key, backend)
    setState(initialValue)
  }, [key, backend, initialValue])

  return [state, setValue, clearValue]
}

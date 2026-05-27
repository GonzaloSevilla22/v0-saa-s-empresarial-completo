"use client"

import { useCallback, useReducer } from "react"

type Status = "idle" | "loading" | "success" | "error" | "empty"

interface RequestState<T> {
  data: T | null
  status: Status
  error: string | null
}

type Action<T> =
  | { type: "LOADING" }
  | { type: "SUCCESS"; payload: T }
  | { type: "EMPTY" }
  | { type: "ERROR"; payload: string }
  | { type: "RESET" }

function reducer<T>(state: RequestState<T>, action: Action<T>): RequestState<T> {
  switch (action.type) {
    case "LOADING":
      return { ...state, status: "loading", error: null }
    case "SUCCESS":
      return { data: action.payload, status: "success", error: null }
    case "EMPTY":
      return { data: null, status: "empty", error: null }
    case "ERROR":
      return { ...state, status: "error", error: action.payload }
    case "RESET":
      return { data: null, status: "idle", error: null }
  }
}

interface UseRequestStateReturn<T> {
  data: T | null
  status: Status
  error: string | null
  isLoading: boolean
  isSuccess: boolean
  isError: boolean
  isEmpty: boolean
  isIdle: boolean
  execute: (promise: Promise<T>) => Promise<T | null>
  reset: () => void
  setData: (data: T) => void
}

/**
 * Centralizes the loading/error/success/empty pattern that was duplicated
 * across ~40 components. Returns a stable `execute()` function that wraps
 * any promise and transitions state automatically.
 *
 * @example
 * const { data, isLoading, isError, error, execute } = useRequestState<Product[]>()
 *
 * useEffect(() => {
 *   execute(fetchProducts())
 * }, [])
 *
 * // In JSX:
 * if (isLoading) return <Skeleton />
 * if (isError) return <ErrorMessage message={error} />
 * if (isEmpty) return <EmptyState />
 */
export function useRequestState<T>(): UseRequestStateReturn<T> {
  const [state, dispatch] = useReducer(reducer<T>, {
    data: null,
    status: "idle",
    error: null,
  })

  const execute = useCallback(async (promise: Promise<T>): Promise<T | null> => {
    dispatch({ type: "LOADING" })
    try {
      const result = await promise
      const isEmpty =
        result === null ||
        result === undefined ||
        (Array.isArray(result) && result.length === 0)

      if (isEmpty) {
        dispatch({ type: "EMPTY" })
      } else {
        dispatch({ type: "SUCCESS", payload: result })
      }
      return result
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Ocurrió un error inesperado"
      dispatch({ type: "ERROR", payload: message })
      return null
    }
  }, [])

  const reset = useCallback(() => dispatch({ type: "RESET" }), [])
  const setData = useCallback(
    (data: T) => dispatch({ type: "SUCCESS", payload: data }),
    [],
  )

  return {
    data: state.data,
    status: state.status,
    error: state.error,
    isLoading: state.status === "loading",
    isSuccess: state.status === "success",
    isError: state.status === "error",
    isEmpty: state.status === "empty",
    isIdle: state.status === "idle",
    execute,
    reset,
    setData,
  }
}

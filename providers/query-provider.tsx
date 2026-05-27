"use client"

import { useState } from "react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { ReactQueryDevtools } from "@tanstack/react-query-devtools"

function makeQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        // Data is considered fresh for 2 minutes — Supabase Realtime handles
        // invalidation on DB changes, so we don't need aggressive polling.
        staleTime: 2 * 60 * 1000,
        // Keep unused query data in cache for 5 minutes before GC.
        gcTime: 5 * 60 * 1000,
        // Retry once on failure (network hiccups), but not for 4xx errors.
        retry: (failureCount, error) => {
          if (error instanceof Error && error.message.includes("No autorizado")) return false
          return failureCount < 1
        },
        refetchOnWindowFocus: false,
      },
      mutations: {
        // Don't retry mutations — they may have partially succeeded.
        retry: false,
      },
    },
  })
}

// Singleton for the server render boundary; each client gets its own instance.
let browserQueryClient: QueryClient | undefined

function getQueryClient() {
  if (typeof window === "undefined") {
    // Server: always create a new client (no singleton leak between requests)
    return makeQueryClient()
  }
  // Client: reuse the same client across re-renders
  if (!browserQueryClient) browserQueryClient = makeQueryClient()
  return browserQueryClient
}

export function QueryProvider({ children }: { children: React.ReactNode }) {
  // useState ensures the client isn't re-created on every render in React 18+
  const [queryClient] = useState(() => getQueryClient())

  return (
    <QueryClientProvider client={queryClient}>
      {children}
      {process.env.NODE_ENV === "development" && (
        <ReactQueryDevtools initialIsOpen={false} buttonPosition="bottom-left" />
      )}
    </QueryClientProvider>
  )
}

"use client"
/**
 * use-greeting.ts
 * Semantic hook that composes AuthContext + user-helpers to expose
 * a ready-to-render, time-aware, personalized greeting.
 *
 * Single source of truth for all greeting display across the app.
 * No direct DB access — the profile is already loaded in AuthContext.
 *
 * Responsibilities:
 *   - Read user.name from AuthContext (never re-fetches from DB)
 *   - Apply capitalizeName, getFirstName, getGreeting helpers
 *   - Expose greeting, firstName, and raw user for convenience
 *   - React automatically to login / logout / profile updates
 *
 * Usage:
 *   const { greeting, firstName, greetingPeriod } = useGreeting()
 *   // greeting       -> "Buen dia, Gonzalo"
 *   // firstName      -> "Gonzalo"
 *   // greetingPeriod -> "Buen dia"
 */

import { useMemo } from "react"
import { useAuth } from "@/contexts/auth-context"
import {
  getGreeting,
  getFirstName,
  getGreetingPeriod,
  capitalizeName,
} from "@/lib/helpers/user-helpers"

export interface UseGreetingResult {
  /** Full greeting: "Buen dia, Gonzalo" */
  greeting: string
  /** First name only, capitalized: "Gonzalo" */
  firstName: string
  /** Time period only: "Buen dia" | "Buenas tardes" | "Buenas noches" */
  greetingPeriod: string
  /** Full name, properly capitalized: "Gonzalo Sevilla" */
  fullName: string
  /** True while the auth session is resolving */
  isLoading: boolean
}

export function useGreeting(fallback = "Emprendedor"): UseGreetingResult {
  const { user, isAuthenticated } = useAuth()

  // All derived values are memoized.
  // They only recompute when user.name changes (i.e. on login, logout,
  // or after updateProfile). The greeting period is stable within a session.
  const firstName = useMemo(
    () => getFirstName(user?.name, fallback),
    [user?.name, fallback]
  )

  const fullName = useMemo(
    () => capitalizeName(user?.name ?? "") || fallback,
    [user?.name, fallback]
  )

  const greetingPeriod = useMemo(() => getGreetingPeriod(), [])

  const greeting = useMemo(
    () => getGreeting(user?.name, fallback),
    [user?.name, fallback]
  )

  return {
    greeting,
    firstName,
    greetingPeriod,
    fullName,
    isLoading: !isAuthenticated && user === null,
  }
}

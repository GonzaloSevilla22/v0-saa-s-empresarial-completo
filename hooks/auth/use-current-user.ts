"use client"

import { useMemo } from "react"
import { useAuth } from "@/contexts/auth-context"

/**
 * Typed accessor for the current user's profile data.
 * Centralizes null-safety so callers don't repeat `user?.profile?.name ?? ""`.
 *
 * @example
 * const { displayName, email, avatarUrl, currency } = useCurrentUser()
 */
export function useCurrentUser() {
  const { user, isAuthenticated, isAdmin } = useAuth()

  return useMemo(
    () => ({
      id: user?.id ?? null,
      email: user?.email ?? "",
      displayName: user?.name ?? user?.email?.split("@")[0] ?? "Usuario",
      firstName: user?.name?.split(" ")[0] ?? "",
      avatarUrl: user?.avatar ?? null,
      currency: user?.currency ?? "ARS",
      timezone: user?.timezone ?? "America/Argentina/Buenos_Aires",
      dateFormat: user?.dateFormat ?? "DD/MM/YYYY",
      language: user?.language ?? "es",
      isAuthenticated,
      isAdmin,
    }),
    [user, isAuthenticated, isAdmin],
  )
}

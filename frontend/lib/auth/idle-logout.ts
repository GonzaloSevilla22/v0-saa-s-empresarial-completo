/**
 * Idle logout action — reuses the existing sign-out mechanism.
 *
 * Design decision (design.md §Decision 1 + §Decision 8):
 *   Idle logout uses the same sign-out path as the regular logout in
 *   auth-context.tsx: supabase.auth.signOut() + clear tenant:active cookie.
 *   It adds `?reason=idle&next=<pathname>` to the redirect so the login page
 *   can explain the session was closed due to inactivity.
 *
 * This function is intentionally extracted from the React hook/provider so it
 * can be unit-tested without a DOM or React context, and so the transport
 * (useIdleTimer) and the logout contract stay decoupled.
 */

import { createClient } from "@/lib/supabase/client"
import { deleteCookie, COOKIE_KEYS } from "@/lib/cookies"

/** Minimal router interface — matches the object returned by `useRouter()`. */
export interface RouterLike {
  push: (url: string) => void
}

/**
 * Performs the idle logout sequence:
 *   1. Sign out from Supabase (local scope, matching the existing `logout()`).
 *   2. Clear the `tenant:active` cookie.
 *   3. Redirect to `/auth/login?reason=idle&next=<currentPath>`.
 *
 * The function is idempotent: if Supabase returns an error (e.g. session already
 * expired), it logs the error and still performs the redirect so the user ends up
 * on the login page regardless.
 *
 * @param router       A `useRouter()` instance (or any object with `.push()`).
 * @param currentPath  The pathname the user was on — encoded as `next` in the URL.
 */
export async function performIdleLogout(
  router: RouterLike,
  currentPath: string,
): Promise<void> {
  const supabase = createClient()

  // Sign out (local scope — same as auth-context.tsx logout())
  const { error } = await supabase.auth.signOut()
  if (error) {
    // Session may already be gone; log but do not throw — always redirect.
    console.warn("[idle-logout] signOut error (proceeding to redirect):", error.message)
  }

  // Clear tenant cookie (same as auth-context.tsx logout())
  deleteCookie(COOKIE_KEYS.TENANT)

  // Redirect with idle context so the login page can explain and return the user.
  const next = encodeURIComponent(currentPath)
  router.push(`/auth/login?reason=idle&next=${next}`)
}

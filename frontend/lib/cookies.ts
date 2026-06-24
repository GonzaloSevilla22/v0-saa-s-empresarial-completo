/**
 * Centralized cookie management for UX preferences.
 *
 * Rules:
 * - Never store sensitive data here (tokens stay in Supabase httpOnly cookies)
 * - All UX cookies: SameSite=Lax, Secure in production, readable client-side for hydration
 * - 1-year max-age for persistent preferences, 7-day for UI state
 */

const IS_PROD = process.env.NODE_ENV === "production"
const SECURE = IS_PROD ? "; Secure" : ""

export const COOKIE_KEYS = {
  THEME:         "ui:theme",
  SIDEBAR:       "ui:sidebar",
  LOCALE:        "ui:locale",
  CURRENCY:      "ui:currency",
  TENANT:        "tenant:active",
  /**
   * Idle-session enforcement: absolute timestamp (ms) of the user's last
   * real interaction, written client-side by the idle timer and read server-side
   * by the middleware. Non-httpOnly by design (Decision 2, idle-server-enforcement
   * change design.md). SameSite=Lax; path=/; Secure in production.
   */
  LAST_ACTIVITY: "auth:last-activity",
} as const

type CookieKey = (typeof COOKIE_KEYS)[keyof typeof COOKIE_KEYS]

const MAX_AGE = {
  YEAR:  60 * 60 * 24 * 365,
  WEEK:  60 * 60 * 24 * 7,
} as const

const COOKIE_CONFIG: Record<CookieKey, { maxAge: number; sameSite: "Lax" | "Strict" }> = {
  "ui:theme":          { maxAge: MAX_AGE.YEAR, sameSite: "Lax"    },
  "ui:sidebar":        { maxAge: MAX_AGE.WEEK, sameSite: "Lax"    },
  "ui:locale":         { maxAge: MAX_AGE.YEAR, sameSite: "Lax"    },
  "ui:currency":       { maxAge: MAX_AGE.YEAR, sameSite: "Lax"    },
  "tenant:active":     { maxAge: MAX_AGE.WEEK, sameSite: "Strict" },
  // maxAge = WEEK: well above the 20-min idle window; the cookie value (not its
  // expiry) drives the idle decision, so a longer lifetime is harmless.
  "auth:last-activity": { maxAge: MAX_AGE.WEEK, sameSite: "Lax"   },
}

// ── Client-side helpers ────────────────────────────────────────────────────

export function setCookie(key: CookieKey, value: string): void {
  if (typeof document === "undefined") return
  const { maxAge, sameSite } = COOKIE_CONFIG[key]
  document.cookie = `${key}=${encodeURIComponent(value)}; path=/; max-age=${maxAge}; SameSite=${sameSite}${SECURE}`
}

export function deleteCookie(key: CookieKey): void {
  if (typeof document === "undefined") return
  document.cookie = `${key}=; path=/; max-age=0`
}

export function getClientCookie(key: CookieKey): string | null {
  if (typeof document === "undefined") return null
  const match = document.cookie
    .split("; ")
    .find((row) => row.startsWith(`${key}=`))
  return match ? decodeURIComponent(match.split("=")[1]) : null
}

// ── Server-side helpers (for Server Components and middleware) ─────────────
// Usage: import { cookies } from "next/headers"; getServerCookie(await cookies(), "ui:theme")

// Duck-typed to avoid importing private Next.js internals that change across versions.
interface CookieStore {
  get(name: string): { value: string } | undefined
}

export function getServerCookie(cookieStore: CookieStore, key: CookieKey): string | null {
  return cookieStore.get(key)?.value ?? null
}

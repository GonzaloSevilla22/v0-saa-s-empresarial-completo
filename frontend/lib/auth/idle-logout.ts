/**
 * Idle logout action — reuses the existing sign-out mechanism.
 *
 * Design decision (design.md §Decision 1 + §Decision 8):
 *   Idle logout uses the same sign-out path as the regular logout in
 *   auth-context.tsx: la acción de servidor `signOutAction({ scope: 'local' })` +
 *   `clearAuthUxCookies()`. It adds `?reason=idle&next=<pathname>` to the
 *   redirect so the login page can explain the session was closed due to
 *   inactivity.
 *
 * This function is intentionally extracted from the React hook/provider so it
 * can be unit-tested without a DOM or React context, and so the transport
 * (useIdleTimer) and the logout contract stay decoupled.
 */

// auth-hardening-jwt-cookies (Parte C, D1, task 18.4g): el cierre de sesión
// corre en el servidor, que es el único que puede borrar las cookies `sb-*`
// httpOnly. Este módulo ya no construye cliente de Supabase.
import { signOutAction } from "@/app/auth/actions"
import { clearAuthUxCookies } from "@/lib/cookies"

/** Minimal router interface — matches the object returned by `useRouter()`. */
export interface RouterLike {
  push: (url: string) => void
}

/**
 * Performs the idle logout sequence:
 *   1. Sign out en el servidor con `scope: 'local'` (igual que `logout()`).
 *   2. Borrar TODAS las cookies de experiencia de la sesión
 *      (`auth:last-activity` y `tenant:active`).
 *   3. Redirect to `/auth/login?reason=idle&next=<currentPath>`.
 *
 * The function is idempotent: if the provider returns an error (e.g. session
 * already expired), it logs the error and still performs the redirect so the user
 * ends up on the login page regardless.
 *
 * @param router       A `useRouter()` instance (or any object with `.push()`).
 * @param currentPath  The pathname the user was on — encoded as `next` in the URL.
 */
export async function performIdleLogout(
  router: RouterLike,
  currentPath: string,
): Promise<void> {
  // auth-hardening-jwt-cookies (D6): `scope: 'local'` explícito. El
  // `signOut()` pelado es GLOBAL por default de la librería
  // (`GoTrueClient.js:3150`), así que cerrar por inactividad en el celular
  // deslogueaba la tablet del mostrador. Ese comentario decía "local scope"
  // desde antes de ser cierto; ahora lo es.
  const result = await signOutAction({ scope: "local" })
  if (!result.ok) {
    // Session may already be gone; log but do not throw — always redirect.
    console.warn("[idle-logout] signOut error (proceeding to redirect):", result.error)
  }

  // D6: borra `auth:last-activity` **y** `tenant:active`. Antes borraba sólo la
  // segunda, y la de actividad sobrevivía una semana: el middleware la leía
  // vencida en el re-login y descartaba las cookies `sb-*` recién emitidas —
  // el bounce del primer reingreso.
  clearAuthUxCookies()

  // Redirect with idle context so the login page can explain and return the user.
  const next = encodeURIComponent(currentPath)
  router.push(`/auth/login?reason=idle&next=${next}`)
}

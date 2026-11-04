/**
 * active-account-store.ts — qué cuenta está mostrando la pantalla, y a quién avisarle
 * cuando el backend dice que esa cuenta quedó vieja.
 *
 * multiusuario-operativo (tanda A, D6). El token es el mismo para todas las pestañas
 * del navegador (las cookies de sesión `httpOnly` son compartidas): al cambiar de
 * cuenta en una, las otras siguen MOSTRANDO la cuenta anterior pero sus requests ya
 * salen con el token nuevo. Para que un alta sin entidad (un gasto, una venta de
 * servicio) escrita desde una pestaña vieja no caiga en la cuenta nueva en silencio,
 * el cliente DECLARA en cada request la cuenta que muestra (`X-Account-Id`,
 * `lib/api/auth-headers.ts`) y el backend responde `409 account_switched` si no
 * coincide.
 *
 * Este módulo existe porque los transportes HTTP (`python-client`, `auth-headers`) no
 * son React y no pueden leer el `AuthContext`. Guarda dos cosas, nada más:
 *
 *  1. La cuenta que muestra la pantalla. La escribe el `AuthProvider` cada vez que
 *     resuelve la cuenta activa. `null` = no declarar ninguna (durante una transición
 *     de cuenta, o sin sesión): el backend entonces no compara.
 *  2. Quién resincroniza. El `AuthProvider` se registra; el cliente HTTP pide la
 *     resincronización ante el `409 account_switched` y ante el `403 No active account
 *     found`. Varios pedidos simultáneos comparten UNA corrida: varios requests de una
 *     pantalla fallan juntos y no deben disparar N renovaciones de token.
 */

let displayedAccountId: string | null = null

/** Declara la cuenta que muestra la pantalla. Una cadena vacía cuenta como ausente. */
export function setDisplayedAccountId(accountId: string | null): void {
  displayedAccountId = accountId ? accountId : null
}

export function getDisplayedAccountId(): string | null {
  return displayedAccountId
}

/** Por qué se pide resincronizar. */
export type AccountResyncReason = "switched" | "no-active-account"

export type AccountResync = (reason: AccountResyncReason) => Promise<void>

let resyncHandler: AccountResync | null = null
let inFlight: Promise<void> | null = null

/**
 * Tope de frecuencia del pedido "sin cuenta activa". Un usuario SIN ninguna membresía recibe ese 403 de
 * TODOS sus requests; cada resincronización descarta la caché y vuelve a pedir, así que sin tope se
 * entra en un lazo (pedir -> 403 -> resincronizar -> descartar -> pedir). `switched` no se limita: es
 * un hecho puntual (otra pestaña cambió de cuenta), no una condición persistente.
 */
const NO_ACTIVE_ACCOUNT_COOLDOWN_MS = 15_000
let lastNoActiveAccountRunAt = 0

/** Registra a quien resincroniza. Devuelve la función de baja. */
export function registerAccountResync(handler: AccountResync): () => void {
  resyncHandler = handler
  return () => {
    if (resyncHandler === handler) resyncHandler = null
  }
}

/**
 * Pide la resincronización de la cuenta.
 *
 * @returns `true` si había alguien registrado y corrió (o ya estaba corriendo);
 *   `false` si no hay a quién avisar, o si es un "sin cuenta activa" repetido dentro del tope.
 */
export async function requestAccountResync(reason: AccountResyncReason): Promise<boolean> {
  const handler = resyncHandler
  if (!handler) return false

  if (!inFlight && reason === "no-active-account") {
    const now = Date.now()
    if (now - lastNoActiveAccountRunAt < NO_ACTIVE_ACCOUNT_COOLDOWN_MS) return false
    lastNoActiveAccountRunAt = now
  }

  if (!inFlight) {
    inFlight = (async () => {
      try {
        await handler(reason)
      } catch (error) {
        // Una resincronización que falla no puede romper al request que la pidió: ese
        // ya tiene su propio error. Se informa y se sigue.
        console.error("[active-account-store] la resincronización de la cuenta falló:", error)
      } finally {
        inFlight = null
      }
    })()
  }
  await inFlight
  return true
}

/** Para los tests: vuelve al estado inicial. */
export function resetActiveAccountStore(): void {
  displayedAccountId = null
  resyncHandler = null
  inFlight = null
  lastNoActiveAccountRunAt = 0
}

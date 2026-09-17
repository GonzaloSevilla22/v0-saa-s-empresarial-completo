/**
 * session-bus.ts — el bus de eventos de sesión de la aplicación.
 *
 * auth-hardening-jwt-cookies (Parte C, D1, grupo 20).
 *
 * ── Por qué existe ──────────────────────────────────────────────────────────
 *
 * Con el cliente de navegador construido con `accessToken` (D1), el observador de
 * estado de autenticación del proveedor **no existe**: `_listenForAuthEvents()` ni
 * se instala (`supabase-js/index.mjs:407`) y cualquier acceso a `supabase.auth`
 * lanza (`:389`). Las dos suscripciones a `onAuthStateChange` que tenía la app
 * (`contexts/auth-context.tsx`, `app/auth/verify-email/page.tsx`) no se pueden
 * "dejar por si acaso": hay que reemplazarlas. Lo que daban y este bus restituye
 * es la propagación **entre pestañas** — cerrar sesión en una y que las demás se
 * enteren, renovar en una y que las demás no queden con un token muerto.
 *
 * ── Sobre qué se monta ──────────────────────────────────────────────────────
 *
 * Sobre el **único** transporte entre pestañas del proyecto
 * (`lib/auth/idle-transport.ts`), no sobre un segundo `BroadcastChannel`
 * (reutilización antes que repetición; hay un test que barre el árbol y falla si
 * nace otro). Eso obligó a resolver antes dos incompatibilidades del transporte,
 * las dos con candado en `__tests__/idle-transport.test.ts`:
 *
 * 1. Admitía **un solo** suscriptor: montarse encima habría desuscrito en
 *    silencio al temporizador de inactividad.
 * 2. `{type:"logout"}` ya **significa** "cierre por inactividad" para su
 *    consumidor, que muestra `?reason=idle`. Este bus **no** lo reutiliza: emite
 *    `session:signed-in`, `session:signed-out` y `session:token-refreshed`.
 *
 * ── Tres reglas del bus ─────────────────────────────────────────────────────
 *
 * 1. **Los mensajes no llevan el token, nunca.** Son señales. El transporte cae a
 *    `localStorage` cuando no hay `BroadcastChannel`, y un token en el mensaje
 *    quedaría escrito en claro — anulando el motivo de la Parte C entera. La
 *    pestaña que recibe la señal le pide el token al manejador.
 * 2. **Lo adoptado no se reanuncia.** Dos pestañas reanunciándose la renovación
 *    mutuamente es un lazo que no se detiene solo. Mientras se adopta una
 *    renovación ajena, el puente con el almacén queda callado.
 * 3. **La adopción es una sola por pestaña**, no una por suscriptor: la hace el
 *    bus, y después avisa.
 */
import {
  createIdleTransport,
  type IdleTransport,
  type SessionMessage,
  type TabMessage,
} from "@/lib/auth/idle-transport"
import {
  clearAccessToken,
  refreshAccessToken,
  subscribeToAccessToken,
} from "@/lib/auth/access-token-store"

export type SessionEvent = SessionMessage["type"]

// ── Estado de módulo ────────────────────────────────────────────────────────

let transport: IdleTransport | null = null
let unsubscribeTransport: (() => void) | null = null
let unsubscribeStore: (() => void) | null = null
/** Verdadero mientras se adopta una renovación ajena (regla 2 del encabezado). */
let adopting = false
/** Último token visto por el puente, para distinguir renovación de primera lectura. */
let lastSeenToken: string | null = null

const subscribers = new Set<(event: SessionEvent) => void>()

function isSessionMessage(msg: TabMessage): msg is SessionMessage {
  return msg.type === "session:signed-in"
    || msg.type === "session:signed-out"
    || msg.type === "session:token-refreshed"
}

function notify(event: SessionEvent): void {
  for (const subscriber of [...subscribers]) {
    try {
      subscriber(event)
    } catch (subscriberError) {
      // Una pantalla que falle al reaccionar no puede impedir que las demás se
      // enteren de que la sesión se cerró.
      console.warn("[session-bus] un suscriptor falló al recibir el evento:", subscriberError)
    }
  }
}

async function adoptRemoteToken(): Promise<void> {
  adopting = true
  try {
    await refreshAccessToken()
  } finally {
    adopting = false
  }
}

function handleInbound(msg: TabMessage): void {
  // Los mensajes del temporizador de inactividad viajan por el mismo canal y no
  // son asunto del bus: `activity` es suyo y `logout` **significa** inactividad.
  if (!isSessionMessage(msg)) return

  if (msg.type === "session:signed-out") {
    // El servidor ya revocó y borró las cookies en la pestaña que cerró; el token
    // en memoria de ESTA pestaña sólo lo puede olvidar ella.
    clearAccessToken()
  } else {
    // Sesión nueva o token rotado en otra pestaña: la cookie compartida ya tiene
    // el valor nuevo, así que pedirlo al manejador NO gasta una renovación contra
    // el proveedor (D19: varias pestañas presentando el mismo refresh token es
    // justamente lo que hay que evitar).
    void adoptRemoteToken()
  }

  notify(msg.type)
}

function ensureBus(): IdleTransport | null {
  if (typeof window === "undefined") return null
  if (transport) return transport

  transport = createIdleTransport()
  unsubscribeTransport = transport.onMessage(handleInbound)

  // Puente con el almacén del token: una renovación **propia** se anuncia a las
  // demás pestañas. La primera lectura de la pestaña no es una renovación, y lo
  // que se acaba de adoptar de otra pestaña tampoco se reanuncia.
  unsubscribeStore = subscribeToAccessToken((token) => {
    const previous = lastSeenToken
    lastSeenToken = token
    if (adopting) return
    if (token === null) return
    if (previous === null || previous === token) return
    publish("session:token-refreshed")
  })

  return transport
}

function publish(event: SessionEvent): void {
  ensureBus()?.post({ type: event } as SessionMessage)
}

// ── API pública ─────────────────────────────────────────────────────────────

/** Avisa a las demás pestañas que esta abrió sesión. */
export function announceSignedIn(): void {
  lastSeenToken = null
  publish("session:signed-in")
}

/** Avisa a las demás pestañas que esta cerró sesión (manual, NO por inactividad). */
export function announceSignedOut(): void {
  lastSeenToken = null
  publish("session:signed-out")
}

/**
 * Avisa a las demás pestañas que el token se renovó.
 *
 * Normalmente no hace falta llamarla: el puente con el almacén la dispara sola
 * cuando el token cambia. Queda expuesta para los caminos que renuevan sin pasar
 * por el almacén.
 */
export function announceTokenRefreshed(): void {
  publish("session:token-refreshed")
}

/**
 * Se entera de los eventos de sesión de las **otras** pestañas.
 *
 * El transporte no le devuelve al emisor sus propios mensajes, así que la pestaña
 * que ejecuta la acción no recibe su propio evento: eso ya lo sabe.
 *
 * @returns función de baja.
 */
export function subscribeToSessionEvents(
  handler: (event: SessionEvent) => void,
): () => void {
  ensureBus()
  subscribers.add(handler)
  return () => {
    subscribers.delete(handler)
  }
}

/**
 * Cierra el canal y olvida el estado del bus.
 *
 * La usan los tests para aislarse entre casos, y cualquier punto de la aplicación
 * que necesite desmontar el bus por completo.
 */
export function closeSessionBus(): void {
  unsubscribeTransport?.()
  unsubscribeStore?.()
  transport?.close()
  unsubscribeTransport = null
  unsubscribeStore = null
  transport = null
  adopting = false
  lastSeenToken = null
  subscribers.clear()
}

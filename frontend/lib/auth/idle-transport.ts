/**
 * Cross-tab transport for idle session timeout.
 *
 * Isolates BroadcastChannel / localStorage behind a small interface so the
 * hook is decoupled from the browser API, tests can swap the transport,
 * and swapping the implementation later requires no changes to consumers.
 *
 * Design decision (design.md §Decision 6):
 *   Primary: BroadcastChannel ("idle-timeout")
 *   Fallback: localStorage key "idle:sync" + storage event
 *
 * Messages:
 *   activity  — { type: "activity"; lastActivity: number }
 *   logout    — { type: "logout" }
 *
 * ── auth-hardening-jwt-cookies (Parte C, D1, grupo 20) ──────────────────────
 *
 * Este transporte es el **único** mecanismo entre pestañas del proyecto, y ahora
 * lo comparten dos consumidores: el temporizador de inactividad y el **bus de
 * eventos de sesión** (`lib/auth/session-bus.ts`), que existe porque con el
 * cliente configurado con `accessToken` el observador del proveedor
 * (`supabase.auth.onAuthStateChange`) ni se instala (`supabase-js/index.mjs:407`)
 * y cualquier acceso a `supabase.auth` lanza (`:389`).
 *
 * Dos cosas cambiaron acá para que apoyarse encima sea seguro, y las dos tienen
 * un candado en `__tests__/idle-transport.test.ts`:
 *
 * 1. **Varios suscriptores.** `onMessage` guardaba **un solo** handler
 *    (`handler = h`, sobrescribiendo) en las dos implementaciones. Montar el bus
 *    sobre la misma instancia habría **desuscrito en silencio** al temporizador de
 *    inactividad: ni aviso previo ni corte, sin un solo error en consola. Hoy es
 *    una lista y `onMessage` devuelve su función de baja.
 * 2. **Tipos propios para la sesión.** `{type:"logout"}` ya **significa** "cierre
 *    por inactividad" para su único consumidor (`components/auth/IdleTimeoutProvider.tsx`,
 *    que muestra `?reason=idle`). El bus **NO** lo reutiliza: emite
 *    `session:signed-in`, `session:signed-out` y `session:token-refreshed`, que el
 *    temporizador ignora porque no pertenecen a su unión.
 */

// ── Message types ─────────────────────────────────────────────────────────────

export interface ActivityMessage {
  type: "activity"
  lastActivity: number
}

export interface LogoutMessage {
  type: "logout"
}

/** Mensajes del temporizador de inactividad. Unión cerrada, no la amplíes. */
export type IdleMessage = ActivityMessage | LogoutMessage

export interface SessionSignedInMessage {
  type: "session:signed-in"
}

export interface SessionSignedOutMessage {
  type: "session:signed-out"
}

export interface SessionTokenRefreshedMessage {
  type: "session:token-refreshed"
}

/**
 * Mensajes del bus de sesión. **Nunca** llevan el access token: el canal cae a
 * `localStorage` cuando `BroadcastChannel` no existe, y escribir el token ahí
 * anularía el motivo del cambio entero (la credencial vive sólo en memoria).
 * Son **señales**: la pestaña que las recibe le pide el token al manejador.
 */
export type SessionMessage =
  | SessionSignedInMessage
  | SessionSignedOutMessage
  | SessionTokenRefreshedMessage

/** Todo lo que puede viajar por el canal compartido. */
export type TabMessage = IdleMessage | SessionMessage

// ── Transport interface ────────────────────────────────────────────────────────

export interface IdleTransport {
  /** Broadcast that the local tab had activity at `lastActivity` (ms timestamp). */
  postActivity(lastActivity: number): void
  /** Broadcast that the local tab is performing an idle logout. */
  postLogout(): void
  /** Publica cualquier mensaje del canal compartido (lo usa el bus de sesión). */
  post(msg: TabMessage): void
  /**
   * Registra un receptor de los mensajes de las otras pestañas.
   *
   * Admite **varios** suscriptores simultáneos y devuelve la función de baja del
   * que se acaba de registrar.
   */
  onMessage(handler: (msg: TabMessage) => void): () => void
  /** Clean up all listeners and close the channel. */
  close(): void
}

// ── Lista de suscriptores (compartida por las dos implementaciones) ──────────

interface SubscriberList {
  add(handler: (msg: TabMessage) => void): () => void
  emit(msg: TabMessage): void
  clear(): void
}

function createSubscriberList(): SubscriberList {
  const handlers = new Set<(msg: TabMessage) => void>()

  return {
    add(handler) {
      handlers.add(handler)
      return () => {
        handlers.delete(handler)
      }
    },
    emit(msg) {
      // Copia: un handler que se da de baja (o que suscribe otro) mientras se
      // reparte el mensaje no puede romper el recorrido.
      for (const handler of [...handlers]) {
        try {
          handler(msg)
        } catch (handlerError) {
          // El temporizador de inactividad y el bus de sesión comparten la
          // instancia: si el primero de la lista explota, el segundo NO puede
          // quedarse sin el mensaje. Un corte por inactividad que no llega es
          // justamente el modo de falla que este transporte existe para evitar.
          console.warn("[idle-transport] un suscriptor falló al recibir el mensaje:", handlerError)
        }
      }
    },
    clear() {
      handlers.clear()
    },
  }
}

// ── BroadcastChannel implementation ──────────────────────────────────────────

const CHANNEL_NAME = "idle-timeout"
const LS_KEY = "idle:sync"

function createBroadcastTransport(): IdleTransport {
  const channel = new BroadcastChannel(CHANNEL_NAME)
  const subscribers = createSubscriberList()

  channel.addEventListener("message", (ev: MessageEvent<TabMessage>) => {
    subscribers.emit(ev.data)
  })

  return {
    postActivity(lastActivity) {
      channel.postMessage({ type: "activity", lastActivity } satisfies ActivityMessage)
    },
    postLogout() {
      channel.postMessage({ type: "logout" } satisfies LogoutMessage)
    },
    post(msg) {
      channel.postMessage(msg)
    },
    onMessage(handler) {
      return subscribers.add(handler)
    },
    close() {
      subscribers.clear()
      channel.close()
    },
  }
}

// ── localStorage fallback ─────────────────────────────────────────────────────

function createLocalStorageTransport(): IdleTransport {
  const subscribers = createSubscriberList()

  const storageListener = (ev: StorageEvent) => {
    if (ev.key !== LS_KEY || !ev.newValue) return
    try {
      const msg = JSON.parse(ev.newValue) as TabMessage
      subscribers.emit(msg)
    } catch {
      // ignore malformed values
    }
  }

  window.addEventListener("storage", storageListener)

  const post = (msg: TabMessage) => {
    // Write → the storage event fires in OTHER tabs (not the current one).
    const payload = JSON.stringify({ ...msg, _t: Date.now() })
    localStorage.setItem(LS_KEY, payload)
  }

  return {
    postActivity(lastActivity) {
      post({ type: "activity", lastActivity })
    },
    postLogout() {
      post({ type: "logout" })
    },
    post,
    onMessage(handler) {
      return subscribers.add(handler)
    },
    close() {
      subscribers.clear()
      window.removeEventListener("storage", storageListener)
    },
  }
}

// ── Factory (auto-selects implementation) ────────────────────────────────────

/**
 * Returns the best available transport for the current browser.
 * BroadcastChannel if supported, localStorage fallback otherwise.
 */
export function createIdleTransport(): IdleTransport {
  if (typeof BroadcastChannel !== "undefined") {
    return createBroadcastTransport()
  }
  return createLocalStorageTransport()
}

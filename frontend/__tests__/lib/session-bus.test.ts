/**
 * auth-hardening-jwt-cookies — Parte C, D1, grupo 20: bus de eventos de sesión.
 *
 * Con el cliente de navegador configurado con `accessToken` (19.6), el observador
 * del proveedor no existe: `_listenForAuthEvents()` ni se instala
 * (`supabase-js/index.mjs:407`) y cualquier acceso a `supabase.auth` lanza
 * (`:389`). Las dos suscripciones a `onAuthStateChange` que había
 * (`contexts/auth-context.tsx`, `app/auth/verify-email/page.tsx`) se reemplazan por
 * este bus, montado sobre el **único** transporte entre pestañas del proyecto
 * (`lib/auth/idle-transport.ts`).
 *
 * Lo que estos tests fijan, en orden de importancia:
 *
 * 1. El cierre de sesión en una pestaña alcanza a las demás (20.1) — y la
 *    credencial en memoria se olvida en la que recibe el aviso, no sólo en la que
 *    cerró.
 * 2. Un cierre **manual** no se confunde con un cierre por **inactividad**
 *    (20.1b). `{type:"logout"}` ya significa "inactividad" para
 *    `IdleTimeoutProvider`, que muestra `?reason=idle`: si el bus lo reutilizara,
 *    cerrar sesión a mano le diría a las otras pestañas una mentira.
 * 3. El temporizador de inactividad sigue recibiendo lo suyo con el bus montado
 *    (20.1b, TRIANGULATE).
 * 4. No nace un segundo transporte entre pestañas (20.2).
 * 5. Una renovación en una pestaña deja a las otras con el token nuevo sin que
 *    cada una lo pida por separado, y **sin** volver a anunciarlo (20.4): el
 *    reanuncio sería un lazo infinito entre dos pestañas.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { FakeBroadcastChannel } from "./fake-broadcast-channel"

// ── Doble del almacén del token ──────────────────────────────────────────────
//
// El bus no guarda el token: lo pide al almacén, que es el único que habla con
// `GET /api/auth/token`. Acá se observa **a quién llama** y se conduce el puente
// de renovación desde el listener que el propio bus registra.

const store = vi.hoisted(() => ({
  clearAccessToken: vi.fn<() => void>(),
  refreshAccessToken: vi.fn(async () => ({ status: "active" as const, token: "nuevo", expiresAt: null, user: null })),
  listeners: new Set<(token: string | null) => void>(),
}))

vi.mock("@/lib/auth/access-token-store", () => ({
  clearAccessToken: store.clearAccessToken,
  refreshAccessToken: store.refreshAccessToken,
  subscribeToAccessToken: (listener: (token: string | null) => void) => {
    store.listeners.add(listener)
    return () => store.listeners.delete(listener)
  },
}))

vi.stubGlobal("BroadcastChannel", FakeBroadcastChannel)

import {
  announceSignedIn,
  announceSignedOut,
  closeSessionBus,
  subscribeToSessionEvents,
  type SessionEvent,
} from "@/lib/auth/session-bus"
import { createIdleTransport, type TabMessage } from "@/lib/auth/idle-transport"

/** Una "otra pestaña": instancia propia del mismo transporte compartido. */
function openPeerTab() {
  const transport = createIdleTransport()
  const received: TabMessage[] = []
  transport.onMessage((msg) => received.push(msg))
  return { transport, received }
}

/** Deja correr las microtareas que el bus dispara sin esperar (adopción). */
const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

describe("session-bus", () => {
  beforeEach(() => {
    vi.stubGlobal("BroadcastChannel", FakeBroadcastChannel)
    FakeBroadcastChannel.reset()
    store.clearAccessToken.mockClear()
    store.refreshAccessToken.mockClear()
    store.listeners.clear()
  })

  afterEach(() => {
    closeSessionBus()
    FakeBroadcastChannel.reset()
  })

  // ── 20.1: el cierre de sesión alcanza a las demás pestañas ────────────────

  it("logout_reaches_other_tabs: el cierre de sesión en una pestaña alcanza a la otra", async () => {
    const seen: SessionEvent[] = []
    subscribeToSessionEvents((event) => seen.push(event))

    // La otra pestaña cierra sesión y lo anuncia por el bus.
    const peer = openPeerTab()
    peer.transport.post({ type: "session:signed-out" })
    await flush()

    expect(seen).toEqual(["session:signed-out"])
    // Y esta pestaña olvida el token: seguir operando con una credencial que el
    // servidor ya revocó es el modo de falla que el cierre existe para evitar.
    expect(store.clearAccessToken).toHaveBeenCalledTimes(1)

    peer.transport.close()
  })

  it("el anuncio local de cierre sale por el transporte compartido hacia las otras pestañas", () => {
    const peer = openPeerTab()

    announceSignedOut()

    expect(peer.received).toEqual([{ type: "session:signed-out" }])
    peer.transport.close()
  })

  it("una sesión iniciada en otra pestaña se adopta y se avisa a los suscriptores", async () => {
    const seen: SessionEvent[] = []
    subscribeToSessionEvents((event) => seen.push(event))

    const peer = openPeerTab()
    peer.transport.post({ type: "session:signed-in" })
    await flush()

    expect(seen).toEqual(["session:signed-in"])
    expect(store.refreshAccessToken).toHaveBeenCalledTimes(1)
    expect(store.clearAccessToken).not.toHaveBeenCalled()

    peer.transport.close()
  })

  it("la función de baja deja de recibir eventos", async () => {
    const seen: SessionEvent[] = []
    const unsubscribe = subscribeToSessionEvents((event) => seen.push(event))
    const peer = openPeerTab()

    peer.transport.post({ type: "session:signed-out" })
    await flush()
    unsubscribe()
    peer.transport.post({ type: "session:signed-in" })
    await flush()

    expect(seen).toEqual(["session:signed-out"])
    peer.transport.close()
  })

  // ── 20.1b: un cierre manual NO es un cierre por inactividad ───────────────

  it("manual_logout_is_not_reported_as_idle: el bus no emite el mensaje del temporizador", () => {
    const peer = openPeerTab()

    // El consumidor real del cierre por inactividad (IdleTimeoutProvider) mira
    // exactamente este predicado y redirige a `?reason=idle`.
    let idleLogoutsSeen = 0
    peer.transport.onMessage((msg) => {
      if (msg.type === "logout") idleLogoutsSeen += 1
    })

    announceSignedIn()
    announceSignedOut()

    expect(idleLogoutsSeen).toBe(0)
    expect(peer.received.map((m) => m.type)).toEqual(["session:signed-in", "session:signed-out"])

    peer.transport.close()
  })

  it("el bus ignora los mensajes del temporizador de inactividad", async () => {
    const seen: SessionEvent[] = []
    subscribeToSessionEvents((event) => seen.push(event))

    const peer = openPeerTab()
    peer.transport.postActivity(1234)
    peer.transport.postLogout()
    await flush()

    // `logout` es del temporizador y significa "inactividad": el bus no lo
    // traduce a un evento de sesión ni borra el token por su cuenta.
    expect(seen).toEqual([])
    expect(store.clearAccessToken).not.toHaveBeenCalled()

    peer.transport.close()
  })

  it("idle_timer_still_receives_activity_messages: el bus montado no desplaza al temporizador", async () => {
    const seen: SessionEvent[] = []
    subscribeToSessionEvents((event) => seen.push(event))

    // El temporizador de inactividad, con su propio suscriptor sobre el mismo
    // transporte compartido.
    const idleTab = createIdleTransport()
    const idleActivity: number[] = []
    idleTab.onMessage((msg) => {
      if (msg.type === "activity") idleActivity.push(msg.lastActivity)
    })

    const peer = openPeerTab()
    peer.transport.postActivity(987)
    peer.transport.post({ type: "session:token-refreshed" })
    await flush()

    expect(idleActivity).toEqual([987])
    expect(seen).toEqual(["session:token-refreshed"])

    idleTab.close()
    peer.transport.close()
  })

  // ── 20.4: la renovación se propaga, y no rebota ───────────────────────────

  it("token_refresh_propagates: la renovación de otra pestaña se adopta una sola vez y no se reanuncia", async () => {
    const seenA: SessionEvent[] = []
    const seenB: SessionEvent[] = []
    subscribeToSessionEvents((event) => seenA.push(event))
    subscribeToSessionEvents((event) => seenB.push(event))

    const peer = openPeerTab()
    peer.received.length = 0
    peer.transport.post({ type: "session:token-refreshed" })
    await flush()

    // Una sola ida al manejador para toda la pestaña, no una por suscriptor.
    expect(store.refreshAccessToken).toHaveBeenCalledTimes(1)
    expect(seenA).toEqual(["session:token-refreshed"])
    expect(seenB).toEqual(["session:token-refreshed"])
    // Y **no** vuelve a anunciar lo que acaba de adoptar: dos pestañas
    // reanunciándose mutuamente es un lazo que no se detiene solo.
    expect(peer.received).toEqual([])

    peer.transport.close()
  })

  it("una renovación propia se anuncia a las otras pestañas", async () => {
    subscribeToSessionEvents(() => {})
    const peer = openPeerTab()

    // El puente con el almacén: primera lectura de la pestaña (no es renovación),
    // después una renovación real.
    expect(store.listeners.size).toBeGreaterThan(0)
    for (const listener of store.listeners) listener("token-1")
    expect(peer.received).toEqual([])

    for (const listener of store.listeners) listener("token-2")
    expect(peer.received).toEqual([{ type: "session:token-refreshed" }])

    peer.transport.close()
  })

  it("el token adoptado de otra pestaña no se reanuncia por el puente del almacén", async () => {
    subscribeToSessionEvents(() => {})
    const peer = openPeerTab()
    for (const listener of store.listeners) listener("token-1")

    // El almacén notifica DURANTE la adopción: es el mismo camino real
    // (`refreshAccessToken()` notifica a sus suscriptores al recibir el token).
    store.refreshAccessToken.mockImplementationOnce(async () => {
      for (const listener of store.listeners) listener("token-remoto")
      return { status: "active" as const, token: "token-remoto", expiresAt: null, user: null }
    })

    peer.received.length = 0
    peer.transport.post({ type: "session:token-refreshed" })
    await flush()

    expect(store.refreshAccessToken).toHaveBeenCalledTimes(1)
    expect(peer.received).toEqual([])

    peer.transport.close()
  })

  it("el mensaje de sesión NUNCA lleva el access token", () => {
    const peer = openPeerTab()

    announceSignedIn()
    announceSignedOut()
    // Valor distintivo: el nombre del propio evento contiene "token", así que un
    // sustring genérico no probaría nada.
    for (const listener of store.listeners) listener("JWT.SECRETO.UNO")
    for (const listener of store.listeners) listener("JWT.SECRETO.DOS")

    expect(peer.received.length).toBeGreaterThanOrEqual(3)
    // El respaldo del transporte escribe en `localStorage`: un token dentro del
    // mensaje quedaría persistido en claro, que es exactamente lo que la Parte C
    // viene a eliminar.
    for (const msg of peer.received) {
      expect(Object.keys(msg)).toEqual(["type"])
      expect(JSON.stringify(msg)).not.toContain("JWT.SECRETO")
    }

    peer.transport.close()
  })
})

// ── 20.2: un solo transporte entre pestañas en todo el proyecto ──────────────

describe("session-bus — no_second_cross_tab_transport", () => {
  const HERE = path.dirname(fileURLToPath(import.meta.url))
  const FRONTEND = path.resolve(HERE, "..", "..")
  const ROOTS = ["app", "components", "hooks", "lib", "contexts", "providers"]
  const TRANSPORT = path.join("lib", "auth", "idle-transport.ts")

  function walk(dir: string, found: string[] = []): string[] {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name)
      if (entry.isDirectory()) {
        if (entry.name === "node_modules" || entry.name === ".next") continue
        walk(full, found)
      } else if (/\.tsx?$/.test(entry.name)) {
        found.push(full)
      }
    }
    return found
  }

  const SOURCE_FILES = ROOTS.flatMap((root) => walk(path.join(FRONTEND, root)))
  const CHANNEL = /new\s+BroadcastChannel\s*\(/

  it("no_second_cross_tab_transport: `new BroadcastChannel` sólo existe en el transporte compartido", () => {
    const offenders = SOURCE_FILES.filter((file) => {
      const relative = path.relative(FRONTEND, file)
      if (relative === TRANSPORT) return false
      return CHANNEL.test(fs.readFileSync(file, "utf8"))
    }).map((file) => path.relative(FRONTEND, file))

    expect(offenders).toEqual([])
  })

  it("el detector no es vacuo: encuentra el canal del transporte compartido", () => {
    const source = fs.readFileSync(path.join(FRONTEND, TRANSPORT), "utf8")
    expect(CHANNEL.test(source)).toBe(true)
    expect(SOURCE_FILES.length).toBeGreaterThan(100)
  })

  it("el bus de sesión reutiliza el transporte compartido en vez de abrir su propio canal", () => {
    const source = fs.readFileSync(path.join(FRONTEND, "lib", "auth", "session-bus.ts"), "utf8")
    expect(source).toContain("@/lib/auth/idle-transport")
    expect(CHANNEL.test(source)).toBe(false)
    expect(source).not.toContain('addEventListener("storage"')
  })
})

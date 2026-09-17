/**
 * Tests for the cross-tab idle transport.
 *
 * Spec coverage:
 *   - Activity broadcast: peers adopt newer lastActivity, ignore older
 *   - Logout broadcast: peers receive the logout message
 *   - localStorage fallback when BroadcastChannel unavailable
 *   - Channel closed on unmount
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"

// ── BroadcastChannel mock ─────────────────────────────────────────────────────
//
// We simulate two "tabs" by creating two instances of the transport and having
// them share a handler registry — the "channel" is a shared in-memory bus.

type MessageHandler = (ev: { data: unknown }) => void

class FakeBroadcastChannel {
  static instances: FakeBroadcastChannel[] = []
  static reset() { FakeBroadcastChannel.instances = [] }

  private listeners: MessageHandler[] = []

  constructor(public name: string) {
    FakeBroadcastChannel.instances.push(this)
  }

  addEventListener(_: "message", handler: MessageHandler) {
    this.listeners.push(handler)
  }

  postMessage(data: unknown) {
    // Deliver to all OTHER instances with the same channel name
    for (const inst of FakeBroadcastChannel.instances) {
      if (inst !== this && inst.name === this.name) {
        for (const h of inst.listeners) h({ data })
      }
    }
  }

  close() {
    const idx = FakeBroadcastChannel.instances.indexOf(this)
    if (idx !== -1) FakeBroadcastChannel.instances.splice(idx, 1)
  }
}

// Patch global before importing the module under test
vi.stubGlobal("BroadcastChannel", FakeBroadcastChannel)

import { createIdleTransport } from "@/lib/auth/idle-transport"

describe("idle-transport — BroadcastChannel", () => {
  beforeEach(() => {
    FakeBroadcastChannel.reset()
  })

  afterEach(() => {
    FakeBroadcastChannel.reset()
  })

  // ── 5.1 RED / 5.2 GREEN: activity broadcast ───────────────────────────────

  it("delivers an activity message with the correct lastActivity to peers", () => {
    const transportA = createIdleTransport()
    const transportB = createIdleTransport()

    const received: unknown[] = []
    transportB.onMessage((msg) => received.push(msg))

    const ts = Date.now()
    transportA.postActivity(ts)

    expect(received).toHaveLength(1)
    expect(received[0]).toEqual({ type: "activity", lastActivity: ts })

    transportA.close()
    transportB.close()
  })

  it("peer ignores activity messages that are older than its own lastActivity", () => {
    // This test is at the hook level (handled in use-idle-timer tests).
    // Here we just verify the transport delivers — filtering is the hook's job.
    const transportA = createIdleTransport()
    const transportB = createIdleTransport()

    const received: unknown[] = []
    transportB.onMessage((msg) => received.push(msg))

    transportA.postActivity(1000)
    expect(received).toHaveLength(1)

    transportA.close()
    transportB.close()
  })

  // ── 5.3 RED / 5.4 GREEN: logout broadcast ────────────────────────────────

  it("delivers a logout message to peers", () => {
    const transportA = createIdleTransport()
    const transportB = createIdleTransport()

    const received: unknown[] = []
    transportB.onMessage((msg) => received.push(msg))

    transportA.postLogout()

    expect(received).toHaveLength(1)
    expect(received[0]).toEqual({ type: "logout" })

    transportA.close()
    transportB.close()
  })

  // ── 5.5 TRIANGULATE: channel closed on unmount ────────────────────────────

  it("close() removes the instance from the channel bus", () => {
    const count0 = FakeBroadcastChannel.instances.length // 0

    const transportA = createIdleTransport()
    const transportB = createIdleTransport()

    expect(FakeBroadcastChannel.instances.length).toBe(count0 + 2)

    transportA.close()
    expect(FakeBroadcastChannel.instances.length).toBe(count0 + 1)

    transportB.close()
    expect(FakeBroadcastChannel.instances.length).toBe(count0)
  })
})

// ── 5.5 TRIANGULATE: localStorage fallback ────────────────────────────────────

describe("idle-transport — localStorage fallback", () => {
  let originalBC: typeof BroadcastChannel

  beforeEach(() => {
    originalBC = global.BroadcastChannel
    // @ts-expect-error intentionally removing to trigger fallback
    delete global.BroadcastChannel
    const store: Record<string, string> = {}
    vi.stubGlobal("localStorage", {
      setItem(k: string, v: string) { store[k] = v },
      getItem(k: string) { return store[k] ?? null },
      removeItem(k: string) { delete store[k] },
    })
  })

  afterEach(() => {
    global.BroadcastChannel = originalBC
    vi.unstubAllGlobals()
  })

  it("postActivity writes to localStorage", () => {
    const transport = createIdleTransport()
    transport.postActivity(12345)

    const stored = localStorage.getItem("idle:sync")
    expect(stored).not.toBeNull()
    const parsed = JSON.parse(stored!)
    expect(parsed.type).toBe("activity")
    expect(parsed.lastActivity).toBe(12345)

    transport.close()
  })

  it("postLogout writes a logout entry to localStorage", () => {
    const transport = createIdleTransport()
    transport.postLogout()

    const stored = localStorage.getItem("idle:sync")
    expect(stored).not.toBeNull()
    const parsed = JSON.parse(stored!)
    expect(parsed.type).toBe("logout")

    transport.close()
  })

  it("receives messages via the storage event", () => {
    const transport = createIdleTransport()
    const received: unknown[] = []
    transport.onMessage((msg) => received.push(msg))

    // Simulate a storage event from another tab
    const event = new StorageEvent("storage", {
      key: "idle:sync",
      newValue: JSON.stringify({ type: "activity", lastActivity: 99999, _t: Date.now() }),
    })
    window.dispatchEvent(event)

    expect(received).toHaveLength(1)
    expect(received[0]).toMatchObject({ type: "activity", lastActivity: 99999 })

    transport.close()
  })
})

// ── 20.0 (auth-hardening-jwt-cookies, Parte C): varios suscriptores ──────────
//
// El bus de eventos de sesión (task 20.1) se monta sobre ESTE transporte, que es
// el único mecanismo cross-tab del proyecto. Hasta este change `onMessage`
// guardaba **un solo** handler (`handler = h`, sobrescribiendo), así que montar el
// bus sobre la misma instancia habría **desuscrito en silencio** al temporizador
// de inactividad: el aviso de "tu sesión va a cerrarse" y el corte por
// inactividad dejaban de recibir los mensajes de las otras pestañas sin un solo
// error. El candado es este bloque.

describe("idle-transport — varios suscriptores (BroadcastChannel)", () => {
  beforeEach(() => {
    // El bloque del respaldo por localStorage corre antes que éste y termina con
    // `vi.unstubAllGlobals()`, que también deshace el `stubGlobal` de módulo: sin
    // volver a poner el doble, acá regiría el `BroadcastChannel` de jsdom, que
    // entrega de forma asíncrona y haría fallar estas aserciones por una razón
    // que no es la que están midiendo.
    vi.stubGlobal("BroadcastChannel", FakeBroadcastChannel)
    FakeBroadcastChannel.reset()
  })

  afterEach(() => {
    FakeBroadcastChannel.reset()
  })

  it("supports_multiple_subscribers: entrega el mensaje a TODOS los handlers registrados", () => {
    const transportA = createIdleTransport()
    const transportB = createIdleTransport()

    const first: unknown[] = []
    const second: unknown[] = []
    transportB.onMessage((msg) => first.push(msg))
    transportB.onMessage((msg) => second.push(msg))

    transportA.postActivity(4242)

    // Sin multi-suscriptor el segundo `onMessage` reemplaza al primero y `first`
    // queda vacío: exactamente el modo de falla del temporizador de inactividad.
    expect(first).toEqual([{ type: "activity", lastActivity: 4242 }])
    expect(second).toEqual([{ type: "activity", lastActivity: 4242 }])

    transportA.close()
    transportB.close()
  })

  it("onMessage devuelve una función de baja que deja de recibir sin afectar a los demás", () => {
    const transportA = createIdleTransport()
    const transportB = createIdleTransport()

    const kept: unknown[] = []
    const dropped: unknown[] = []
    transportB.onMessage((msg) => kept.push(msg))
    const unsubscribe = transportB.onMessage((msg) => dropped.push(msg))

    transportA.postActivity(1)
    unsubscribe()
    transportA.postActivity(2)

    expect(kept).toHaveLength(2)
    expect(dropped).toHaveLength(1)

    transportA.close()
    transportB.close()
  })

  it("close() corta a todos los suscriptores de esa instancia", () => {
    const transportA = createIdleTransport()
    const transportB = createIdleTransport()

    const received: unknown[] = []
    transportB.onMessage((msg) => received.push(msg))
    transportB.onMessage((msg) => received.push(msg))

    transportB.close()
    transportA.postActivity(7)

    expect(received).toHaveLength(0)

    transportA.close()
  })

  it("un handler que lanza no impide que los siguientes reciban el mensaje", () => {
    const transportA = createIdleTransport()
    const transportB = createIdleTransport()

    const warn = vi.spyOn(console, "warn").mockImplementation(() => {})
    const received: unknown[] = []
    transportB.onMessage(() => {
      throw new Error("un consumidor roto")
    })
    transportB.onMessage((msg) => received.push(msg))

    transportA.postLogout()

    // El corte por inactividad y el bus de sesión comparten la instancia: si el
    // primero de la lista explota, el segundo NO puede quedarse sin el mensaje.
    expect(received).toEqual([{ type: "logout" }])
    expect(warn).toHaveBeenCalled()

    warn.mockRestore()
    transportA.close()
    transportB.close()
  })
})

describe("idle-transport — varios suscriptores (localStorage)", () => {
  let originalBC: typeof BroadcastChannel

  beforeEach(() => {
    originalBC = global.BroadcastChannel
    // @ts-expect-error intentionally removing to trigger fallback
    delete global.BroadcastChannel
    const store: Record<string, string> = {}
    vi.stubGlobal("localStorage", {
      setItem(k: string, v: string) { store[k] = v },
      getItem(k: string) { return store[k] ?? null },
      removeItem(k: string) { delete store[k] },
    })
  })

  afterEach(() => {
    global.BroadcastChannel = originalBC
    vi.unstubAllGlobals()
  })

  it("supports_multiple_subscribers: el respaldo por localStorage también entrega a todos", () => {
    const transport = createIdleTransport()

    const first: unknown[] = []
    const second: unknown[] = []
    transport.onMessage((msg) => first.push(msg))
    const unsubscribe = transport.onMessage((msg) => second.push(msg))

    window.dispatchEvent(new StorageEvent("storage", {
      key: "idle:sync",
      newValue: JSON.stringify({ type: "activity", lastActivity: 555, _t: Date.now() }),
    }))

    expect(first).toHaveLength(1)
    expect(second).toHaveLength(1)

    unsubscribe()
    window.dispatchEvent(new StorageEvent("storage", {
      key: "idle:sync",
      newValue: JSON.stringify({ type: "logout", _t: Date.now() }),
    }))

    expect(first).toHaveLength(2)
    expect(second).toHaveLength(1)

    transport.close()
  })
})

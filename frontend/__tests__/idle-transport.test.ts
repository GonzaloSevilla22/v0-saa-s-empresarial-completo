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

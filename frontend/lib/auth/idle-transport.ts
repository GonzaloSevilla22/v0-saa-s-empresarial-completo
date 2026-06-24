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
 */

// ── Message types ─────────────────────────────────────────────────────────────

export interface ActivityMessage {
  type: "activity"
  lastActivity: number
}

export interface LogoutMessage {
  type: "logout"
}

export type IdleMessage = ActivityMessage | LogoutMessage

// ── Transport interface ────────────────────────────────────────────────────────

export interface IdleTransport {
  /** Broadcast that the local tab had activity at `lastActivity` (ms timestamp). */
  postActivity(lastActivity: number): void
  /** Broadcast that the local tab is performing an idle logout. */
  postLogout(): void
  /** Register a callback for incoming messages from other tabs. */
  onMessage(handler: (msg: IdleMessage) => void): void
  /** Clean up all listeners and close the channel. */
  close(): void
}

// ── BroadcastChannel implementation ──────────────────────────────────────────

const CHANNEL_NAME = "idle-timeout"
const LS_KEY = "idle:sync"

function createBroadcastTransport(): IdleTransport {
  const channel = new BroadcastChannel(CHANNEL_NAME)
  let handler: ((msg: IdleMessage) => void) | null = null

  channel.addEventListener("message", (ev: MessageEvent<IdleMessage>) => {
    handler?.(ev.data)
  })

  return {
    postActivity(lastActivity) {
      channel.postMessage({ type: "activity", lastActivity } satisfies ActivityMessage)
    },
    postLogout() {
      channel.postMessage({ type: "logout" } satisfies LogoutMessage)
    },
    onMessage(h) {
      handler = h
    },
    close() {
      channel.close()
    },
  }
}

// ── localStorage fallback ─────────────────────────────────────────────────────

function createLocalStorageTransport(): IdleTransport {
  let handler: ((msg: IdleMessage) => void) | null = null

  const storageListener = (ev: StorageEvent) => {
    if (ev.key !== LS_KEY || !ev.newValue) return
    try {
      const msg = JSON.parse(ev.newValue) as IdleMessage
      handler?.(msg)
    } catch {
      // ignore malformed values
    }
  }

  window.addEventListener("storage", storageListener)

  const post = (msg: IdleMessage) => {
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
    onMessage(h) {
      handler = h
    },
    close() {
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

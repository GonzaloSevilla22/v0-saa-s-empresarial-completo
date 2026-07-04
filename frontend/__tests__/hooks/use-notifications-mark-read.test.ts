/**
 * TDD tests for markNotificationRead (v3-notifications-realtime, task 6.6)
 * Verifica: baja el badge (UPDATE con read=true) y es idempotente (re-marcar
 * una ya leída no rompe — el segundo UPDATE simplemente no afecta filas).
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { markNotificationRead } from "@/hooks/data/use-notifications"

function buildSupabaseMock() {
  const updateMock = vi.fn()
  const eqAccountMock = vi.fn()
  const eqReadMock = vi.fn()

  const chain = {
    update: updateMock,
    eq: eqAccountMock,
  }

  updateMock.mockReturnValue({ eq: eqReadMock })
  eqReadMock.mockImplementation(() => {
    // .eq("id", id) devuelve otro objeto encadenable con .eq("read", false)
    return { eq: eqReadMock2 }
  })

  const eqReadMock2 = vi.fn().mockResolvedValue({ error: null })

  return {
    from: vi.fn().mockReturnValue(chain),
    updateMock,
    eqReadMock,
    eqReadMock2,
  }
}

describe("markNotificationRead", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("marca la notificación como leída (UPDATE read=true + read_at)", async () => {
    const supabaseMock = buildSupabaseMock()

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await markNotificationRead(supabaseMock as any, "notif-1")

    expect(supabaseMock.from).toHaveBeenCalledWith("notifications")
    expect(supabaseMock.updateMock).toHaveBeenCalledWith(
      expect.objectContaining({ read: true, read_at: expect.any(String) }),
    )
  })

  it("es idempotente: re-marcar una ya leída no lanza error (UPDATE no afecta filas)", async () => {
    const supabaseMock = buildSupabaseMock()

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await expect(markNotificationRead(supabaseMock as any, "notif-1")).resolves.not.toThrow()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await expect(markNotificationRead(supabaseMock as any, "notif-1")).resolves.not.toThrow()
  })
})

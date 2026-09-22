/**
 * accounts-profiles-privilege-columns — `POST /api/billing/cancel`.
 *
 * Esta ruta era el ÚNICO caller que escribía `public.accounts` por PostgREST
 * con el JWT del usuario (rol `authenticated`), el mismo mecanismo con el que
 * un titular podía auto-otorgarse `billing_exempt` / `billing_plan`. La
 * migración 20261053000001 le revoca el UPDATE de tabla a `authenticated`, así
 * que la ruta pasa a la RPC `rpc_request_subscription_cancellation()`
 * (SECURITY DEFINER, sin parámetros, exige ser el TITULAR).
 *
 * Lo que fijan estos tests:
 *   · La ruta llama a la RPC y NUNCA hace `.from('accounts')` (si volviera a
 *     hacerlo, en producción devolvería 500 por permission denied).
 *   · `expiresAt` y el `from_plan` del evento de auditoría salen de lo que
 *     devuelve la RPC, no de un cálculo del cliente.
 *   · El mapeo de los ERRCODEs del guard a los status HTTP, incluido el
 *     P0403 de "no sos el titular" — antes un miembro no titular recibía
 *     `{ok:true}` con 0 filas afectadas (falsa confirmación de cancelación).
 */

import { describe, it, expect, vi, beforeEach } from "vitest"

const { mockGetUser, mockRpc, mockInsert, mockFrom } = vi.hoisted(() => ({
  mockGetUser: vi.fn(),
  mockRpc: vi.fn(),
  mockInsert: vi.fn(),
  mockFrom: vi.fn(),
}))

vi.mock("@/lib/supabase/server", () => ({
  createClient: () => ({
    auth: { getUser: mockGetUser },
    rpc: mockRpc,
    from: mockFrom,
  }),
}))

import { POST } from "@/app/api/billing/cancel/route"

const USER = { id: "user-1", email: "titular@test.local" }
const EXPIRES = "2026-10-21T12:00:00+00:00"

interface PostgrestLikeError {
  code: string
  message: string
}

function rpcOk(): void {
  mockRpc.mockResolvedValue({
    data: { account_id: "acc-1", from_plan: "pro", plan_expires_at: EXPIRES },
    error: null,
  })
}

function rpcFails(error: PostgrestLikeError): void {
  mockRpc.mockResolvedValue({ data: null, error })
}

describe("POST /api/billing/cancel — cancelación vía RPC, sin UPDATE directo de accounts", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mockGetUser.mockResolvedValue({ data: { user: USER }, error: null })
    mockInsert.mockResolvedValue({ error: null })
    mockFrom.mockImplementation(() => ({ insert: mockInsert }))
  })

  it("llama a rpc_request_subscription_cancellation y NUNCA a from('accounts')", async () => {
    rpcOk()

    const res = await POST()
    const body = (await res.json()) as { ok: boolean; expiresAt?: string }

    expect(mockRpc).toHaveBeenCalledWith("rpc_request_subscription_cancellation", {})
    expect(mockFrom.mock.calls.map((c) => c[0])).not.toContain("accounts")
    expect(res.status).toBe(200)
    expect(body).toEqual({ ok: true, expiresAt: EXPIRES })
  })

  it("audita en billing_events con el from_plan y la fecha que devolvió la RPC", async () => {
    rpcOk()

    await POST()

    expect(mockFrom.mock.calls.map((c) => c[0])).toContain("billing_events")
    const auditPayload = mockInsert.mock.calls
      .map((c) => c[0] as Record<string, unknown>)
      .find((p) => p.event_type === "cancellation_requested")
    expect(auditPayload).toMatchObject({ from_plan: "pro", to_plan: "gratis", user_id: USER.id })
    expect(auditPayload?.metadata).toMatchObject({ account_id: "acc-1", plan_expires_at: EXPIRES })
  })

  it("P0403 (no es el titular) → 403, no una falsa confirmación", async () => {
    rpcFails({ code: "P0403", message: "not_account_owner: ..." })

    const res = await POST()
    const body = (await res.json()) as { ok: boolean; error?: string }

    expect(res.status).toBe(403)
    expect(body.ok).toBe(false)
    expect(body.error).toMatch(/titular/i)
    // No se audita ni se encola mail de algo que no pasó.
    expect(mockInsert).not.toHaveBeenCalled()
  })

  it("P0400 (sin plan pago) → 400 con el mensaje de siempre", async () => {
    rpcFails({ code: "P0400", message: "no_active_paid_plan: ..." })

    const res = await POST()
    const body = (await res.json()) as { ok: boolean; error?: string }

    expect(res.status).toBe(400)
    expect(body.error).toBe("No hay un plan pago activo para cancelar")
  })

  it("P0409 (ya programada) → 400 con el mensaje de siempre", async () => {
    rpcFails({ code: "P0409", message: "cancellation_already_scheduled: ..." })

    const res = await POST()
    const body = (await res.json()) as { ok: boolean; error?: string }

    expect(res.status).toBe(400)
    expect(body.error).toBe("La cancelación ya está programada")
  })

  it("P0404 (sin cuenta) → 404", async () => {
    rpcFails({ code: "P0404", message: "account_not_found" })

    const res = await POST()

    expect(res.status).toBe(404)
  })

  it("un error inesperado de la RPC → 500 y no se audita", async () => {
    rpcFails({ code: "42501", message: "permission denied for table accounts" })

    const res = await POST()
    const body = (await res.json()) as { ok: boolean; error?: string }

    expect(res.status).toBe(500)
    expect(body.ok).toBe(false)
    expect(mockInsert).not.toHaveBeenCalled()
  })

  it("sin sesión → 401 y sin tocar la RPC", async () => {
    mockGetUser.mockResolvedValue({ data: { user: null }, error: null })

    const res = await POST()

    expect(res.status).toBe(401)
    expect(mockRpc).not.toHaveBeenCalled()
  })
})

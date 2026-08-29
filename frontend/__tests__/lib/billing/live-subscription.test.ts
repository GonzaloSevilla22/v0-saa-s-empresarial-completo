/**
 * planes-suscribirse-plan-vigente (grupo 2, D1/D2) — helper canónico de
 * lectura de "suscripción viva" (`public.subscriptions`,
 * `status IN ('pending','authorized')`), extraído del patrón que
 * `/facturacion` ya usaba inline (`app/(dashboard)/facturacion/page.tsx`
 * L138-145) para que `/planes` lo reuse sin duplicar la consulta.
 *
 * El predicado de "vivo" DEBE ser exactamente el de
 * `subscriptions_repository.find_live_subscription` (backend, verificado
 * en tasks 1.2/1.3): `status IN ('pending', 'authorized')`. Si diverge, la
 * UI ofrece contrataciones que el backend rechaza con 409, o las esconde
 * sin motivo (D2). El helper no confía únicamente en el filtro SQL: vuelve
 * a chequear el status client-side antes de considerar la fila "viva"
 * (defensa en profundidad — cache stale, mock de test, o un futuro cambio
 * de la consulta que se olvide del `.in()`).
 */
import { describe, it, expect, vi } from "vitest"
import {
  getLiveSubscription,
  LIVE_SUBSCRIPTION_STATUSES,
  type LiveSubscriptionRow,
} from "@/lib/billing/live-subscription"

type MockClient = Parameters<typeof getLiveSubscription>[0]

function mockClientResolving(resolved: { data: unknown; error: unknown }): MockClient {
  const builder = {
    select: vi.fn(() => builder),
    eq: vi.fn(() => builder),
    in: vi.fn(() => builder),
    maybeSingle: vi.fn(() => Promise.resolve(resolved)),
  }
  return { from: vi.fn(() => builder) } as unknown as MockClient
}

function mockClientThrowing(): MockClient {
  return {
    from: vi.fn(() => {
      throw new Error("network boom")
    }),
  } as unknown as MockClient
}

const LIVE_ROW: LiveSubscriptionRow = {
  plan: "avanzado",
  status: "authorized",
  next_payment_date: "2026-09-15T12:00:00Z",
  retry_state: "none",
  amount: null,
  currency: "ARS",
}

describe("getLiveSubscription — contrato (2.1)", () => {
  it("cuenta con fila status='authorized' devuelve la fila (viva)", async () => {
    const client = mockClientResolving({ data: LIVE_ROW, error: null })

    const result = await getLiveSubscription(client, "acc-1")

    expect(result).toEqual(LIVE_ROW)
  })

  it("cuenta sin filas devuelve null (no viva)", async () => {
    const client = mockClientResolving({ data: null, error: null })

    const result = await getLiveSubscription(client, "acc-1")

    expect(result).toBeNull()
  })
})

describe("getLiveSubscription — triangulación (2.3)", () => {
  it("status='pending' también es viva", async () => {
    const pendingRow: LiveSubscriptionRow = { ...LIVE_ROW, status: "pending" }
    const client = mockClientResolving({ data: pendingRow, error: null })

    const result = await getLiveSubscription(client, "acc-1")

    expect(result).toEqual(pendingRow)
  })

  it("status='cancelled' -> NO viva (defensa en profundidad, no confía solo en el filtro SQL)", async () => {
    const cancelledRow: LiveSubscriptionRow = { ...LIVE_ROW, status: "cancelled" }
    const client = mockClientResolving({ data: cancelledRow, error: null })

    const result = await getLiveSubscription(client, "acc-1")

    expect(result).toBeNull()
  })

  it("status='ambiguous' -> NO viva (la fila del incidente del 29-08 nunca cuenta como viva)", async () => {
    const ambiguousRow: LiveSubscriptionRow = { ...LIVE_ROW, status: "ambiguous" }
    const client = mockClientResolving({ data: ambiguousRow, error: null })

    const result = await getLiveSubscription(client, "acc-1")

    expect(result).toBeNull()
  })

  it("consulta con account_id y el filtro de estados vivos correcto", async () => {
    const builder = {
      select: vi.fn(() => builder),
      eq: vi.fn(() => builder),
      in: vi.fn(() => builder),
      maybeSingle: vi.fn(() => Promise.resolve({ data: null, error: null })),
    }
    const client = { from: vi.fn(() => builder) } as unknown as MockClient

    await getLiveSubscription(client, "acc-42")

    expect(client.from).toHaveBeenCalledWith("subscriptions")
    expect(builder.eq).toHaveBeenCalledWith("account_id", "acc-42")
    expect(builder.in).toHaveBeenCalledWith("status", ["pending", "authorized"])
  })

  it("cuenta sin accountId (undefined) -> no viva, sin lanzar y sin consultar", async () => {
    const client = mockClientResolving({ data: null, error: null })

    const result = await getLiveSubscription(client, undefined)

    expect(result).toBeNull()
    expect(client.from as ReturnType<typeof vi.fn>).not.toHaveBeenCalled()
  })

  it("cuenta sin accountId (null) -> no viva, sin lanzar y sin consultar", async () => {
    const client = mockClientResolving({ data: null, error: null })

    const result = await getLiveSubscription(client, null)

    expect(result).toBeNull()
    expect(client.from as ReturnType<typeof vi.fn>).not.toHaveBeenCalled()
  })

  it("error de consulta (Postgrest error) -> no viva, sin lanzar", async () => {
    const client = mockClientResolving({ data: null, error: { message: "boom" } })

    const result = await getLiveSubscription(client, "acc-1")

    expect(result).toBeNull()
  })

  it("excepción de red al consultar -> no viva, sin lanzar (la pantalla de planes nunca debe caerse)", async () => {
    const client = mockClientThrowing()

    await expect(getLiveSubscription(client, "acc-1")).resolves.toBeNull()
  })
})

describe("getLiveSubscription — paridad de estados con el backend (2.4)", () => {
  // Enumeración explícita, NO importada de la implementación: el objetivo
  // es que este test rompa si alguien agrega/quita un estado de un solo
  // lado (frontend o backend). No existe una constante compartida entre
  // Python y TypeScript (cruza el límite de lenguaje/deploy), así que la
  // duplicación es real y deliberada — este test es lo que la vigila.
  //
  // Fuente de la verdad en el backend (tasks 1.2/1.3):
  // backend/repositories/subscriptions_repository.py, find_live_subscription:
  //   WHERE account_id = $1 AND status IN ('pending', 'authorized')
  it("el conjunto de estados vivos es exactamente ('pending', 'authorized')", () => {
    expect(LIVE_SUBSCRIPTION_STATUSES).toEqual(["pending", "authorized"])
  })
})

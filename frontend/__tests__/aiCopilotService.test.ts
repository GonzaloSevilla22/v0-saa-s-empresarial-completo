/**
 * app-timezone-argentina, task 3.2: `getBusinessDataContext` calcula la
 * ventana de "últimos 30 días" a partir de `now`. La cota inferior
 * (`thirtyDaysAgoStr`) debe anclarse al día ARGENTINO, no al día UTC del
 * server — a las 22:00 ART el día UTC ya rolleó y la ventana se corría un
 * día. Línea base = 0 (no existían tests de este servicio).
 */

import { describe, it, expect, vi, afterEach } from "vitest"
import type { SupabaseClient } from "@supabase/supabase-js"
import { aiCopilotService } from "@/lib/services/aiCopilotService"

interface FakeResult<T> {
  data: T[] | null
  error: { message: string } | null
}

interface FakeQueryBuilder<T> extends PromiseLike<FakeResult<T>> {
  select(columns: string): FakeQueryBuilder<T>
  gte(column: string, value: string): FakeQueryBuilder<T>
  order(column: string, opts?: { ascending: boolean }): FakeQueryBuilder<T>
  limit(n: number): FakeQueryBuilder<T>
}

function makeBuilder<T>(result: FakeResult<T>, onGte: (column: string, value: string) => void): FakeQueryBuilder<T> {
  const builder: FakeQueryBuilder<T> = {
    select: () => builder,
    gte: (column: string, value: string) => {
      onGte(column, value)
      return builder
    },
    order: () => builder,
    limit: () => builder,
    then: (onfulfilled, onrejected) => Promise.resolve(result).then(onfulfilled, onrejected),
  }
  return builder
}

function makeSupabaseDouble(gteCalls: string[]): SupabaseClient {
  const fromMock = vi.fn((_table: string) => ({
    select: () => makeBuilder({ data: [], error: null }, (_col, value) => gteCalls.push(value)),
  }))
  return { from: fromMock } as unknown as SupabaseClient
}

describe("aiCopilotService.getBusinessDataContext — ventana ART (app-timezone-argentina)", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("REGRESSION: a las 22:00 ART la cota de 30 días es el día ART, no el día UTC D+1", async () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-06-09T01:00:00.000Z")) // 22:00 ART, 8/jun

    const gteCalls: string[] = []
    const supabase = makeSupabaseDouble(gteCalls)

    await aiCopilotService.getBusinessDataContext(supabase)

    // 30 días ART antes del 8/jun (no del 9/jun, que sería el bug UTC).
    expect(gteCalls.every((v) => v === "2026-05-09")).toBe(true)
    expect(gteCalls.length).toBeGreaterThan(0)
  })
})

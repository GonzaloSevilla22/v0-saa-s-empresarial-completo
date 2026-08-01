/**
 * Tests for the shared effective-plan resolution module used by Edge Functions
 * (billing-edge-effective-plan, D6).
 *
 * Unlike ai-precio.test.ts (which re-declares pure logic because ai-precio's
 * Deno.serve handler cannot be imported), this file imports the REAL file
 * `supabase/functions/_shared/effective-plan.ts` by relative path. D6 requires
 * that module to be pure and injectable (no `Deno.*` at module scope) so a
 * reimplementation of the rule locally would NOT be covered by this test —
 * only importing the actual file achieves that.
 *
 * Run: pnpm vitest run __tests__/edge-effective-plan.test.ts
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import {
  resolveEffectivePlan,
  type EffectivePlanClient,
} from "../../supabase/functions/_shared/effective-plan"

function makeClient(
  response: { data: string | null; error: { message: string } | null },
): EffectivePlanClient {
  return {
    rpc: vi.fn().mockResolvedValue(response),
  }
}

describe("resolveEffectivePlan (task 3.1 — RPC returns 'pro')", () => {
  it("returns 'pro' when the RPC resolves to 'pro'", async () => {
    const client = makeClient({ data: "pro", error: null })
    const plan = await resolveEffectivePlan(client)
    expect(plan).toBe("pro")
  })
})

describe("resolveEffectivePlan (task 3.3 — triangulation)", () => {
  let errorSpy: ReturnType<typeof vi.spyOn>

  beforeEach(() => {
    errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
  })

  it("returns 'gratis' when the RPC resolves to 'gratis'", async () => {
    const client = makeClient({ data: "gratis", error: null })
    expect(await resolveEffectivePlan(client)).toBe("gratis")
  })

  it("returns 'gratis' when the RPC returns null", async () => {
    const client = makeClient({ data: null, error: null })
    expect(await resolveEffectivePlan(client)).toBe("gratis")
  })

  it("returns 'gratis' when the RPC returns an empty string", async () => {
    const client = makeClient({ data: "", error: null })
    expect(await resolveEffectivePlan(client)).toBe("gratis")
  })

  it("returns 'gratis' AND logs the error when the RPC call errors (fail-closed, observable — D5)", async () => {
    const client = makeClient({ data: null, error: { message: "connection reset" } })
    const plan = await resolveEffectivePlan(client)
    expect(plan).toBe("gratis")
    expect(errorSpy).toHaveBeenCalledTimes(1)
    expect(errorSpy.mock.calls[0].join(" ")).toContain("connection reset")
  })

  it("returns 'gratis' when the RPC returns an unrecognized value", async () => {
    const client = makeClient({ data: "enterprise", error: null })
    expect(await resolveEffectivePlan(client)).toBe("gratis")
  })

  it.each(["inicial", "avanzado"] as const)(
    "returns the plan unchanged for a recognized non-default value ('%s')",
    async (plan) => {
      const client = makeClient({ data: plan, error: null })
      expect(await resolveEffectivePlan(client)).toBe(plan)
    },
  )
})

describe("resolveEffectivePlan (task 3.4 — isolation: no caller-provided account_id)", () => {
  it("accepts only the client — the function signature has no account_id parameter", () => {
    // Arity check: resolveEffectivePlan(supabase) — a caller cannot pass a
    // second argument that would select an arbitrary account. This is
    // enforced by construction (TypeScript signature), not by a runtime
    // guard, so the test asserts the arity directly.
    expect(resolveEffectivePlan.length).toBe(1)
  })

  it("calls the RPC with no arguments beyond the function name — no account_id is forwarded", async () => {
    const client = makeClient({ data: "pro", error: null })
    await resolveEffectivePlan(client)
    const rpcMock = client.rpc as ReturnType<typeof vi.fn>
    expect(rpcMock).toHaveBeenCalledTimes(1)
    expect(rpcMock).toHaveBeenCalledWith("rpc_my_effective_plan")
    // Exactly one argument reached the client — the function name. Nothing
    // resembling an account identifier was appended.
    expect(rpcMock.mock.calls[0]).toHaveLength(1)
  })
})

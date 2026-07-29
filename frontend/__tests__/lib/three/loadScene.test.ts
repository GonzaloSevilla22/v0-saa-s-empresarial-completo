/**
 * Tests for `loadScene` (lib/three/loadScene.ts) — the `next/dynamic`
 * loading convention for 3D scenes (design.md D2, task 2.6): every scene
 * MUST load `ssr:false` (no WebGL on the server; avoids hydration mismatch)
 * and MUST have a `loading` fallback so there is never a blank gap while the
 * scene's chunk downloads — never call `next/dynamic` ad-hoc per scene.
 *
 * `next/dynamic` itself is mocked — this test only verifies `loadScene`
 * always passes the two non-negotiable options through correctly, not
 * `next/dynamic`'s own lazy-loading mechanics (Next.js's own concern).
 *
 * Cycle: RED (module doesn't exist yet) → GREEN → TRIANGULATE → REFACTOR.
 */

import { describe, it, expect, vi } from "vitest"

interface MockDynamicOptions {
  ssr: boolean
  loading: () => unknown
}

const { mockDynamic } = vi.hoisted(() => ({
  mockDynamic: vi.fn((_importer: () => Promise<unknown>, _options: MockDynamicOptions) => "DynamicComponent"),
}))
vi.mock("next/dynamic", () => ({ default: mockDynamic }))

const { loadScene } = await import("@/lib/three/loadScene")

describe("loadScene", () => {
  // ── RED/GREEN: always ssr:false + forwards the importer ─────────────────
  it("calls next/dynamic with ssr:false and the given importer", () => {
    const importer = () => Promise.resolve({ default: () => null })
    const loading = () => null

    loadScene(importer, loading)

    expect(mockDynamic).toHaveBeenCalledTimes(1)
    const [passedImporter, options] = mockDynamic.mock.calls[0]
    expect(passedImporter).toBe(importer)
    expect(options).toMatchObject({ ssr: false })
  })

  // ── TRIANGULATE: forwards the loading fallback (never omitted) ──────────
  it("forwards the loading fallback so there is never a blank gap while the chunk downloads", () => {
    const importer = () => Promise.resolve({ default: () => null })
    const loading = () => "poster"

    loadScene(importer, loading)

    const [, options] = mockDynamic.mock.calls[mockDynamic.mock.calls.length - 1]
    expect(typeof options.loading).toBe("function")
    expect(options.loading()).toBe("poster")
  })
})

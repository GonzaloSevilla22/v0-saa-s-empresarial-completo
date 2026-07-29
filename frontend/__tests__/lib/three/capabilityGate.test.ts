/**
 * Tests for the 3D capability gate (design.md D5 / spec `immersive-3d-surfaces`,
 * Requirement "Gate de capacidad con fallback estático").
 *
 * `evaluateCapabilityGate` is a pure function over an explicit `CapabilitySignals`
 * snapshot — kept pure (no `window`/`navigator` reads inside) so every fallback
 * condition is unit-testable without mocking the DOM/BOM.
 *
 * Cycle: RED → GREEN → TRIANGULATE.
 */

import { describe, it, expect } from "vitest"
import {
  evaluateCapabilityGate,
  MOBILE_VIEWPORT_MAX_WIDTH_PX,
  LOW_END_HARDWARE_CONCURRENCY_MAX,
  LOW_END_DEVICE_MEMORY_MAX_GB,
  type CapabilitySignals,
} from "@/lib/three/capabilityGate"

/** A signals snapshot that qualifies for 3D on every axis — mutate per test. */
function qualifyingSignals(overrides: Partial<CapabilitySignals> = {}): CapabilitySignals {
  return {
    prefersReducedMotion: false,
    hasWebGL: true,
    hardwareConcurrency: 8,
    deviceMemory: 8,
    pointerCoarse: false,
    viewportWidth: 1440,
    saveData: false,
    slowEffectiveType: false,
    ...overrides,
  }
}

describe("evaluateCapabilityGate", () => {
  // ── Caso "califica" ──────────────────────────────────────────────────────
  it("qualifies when every signal is favorable (desktop, WebGL, fast connection)", () => {
    const result = evaluateCapabilityGate(qualifyingSignals())
    expect(result).toEqual({ qualifies: true, reason: "qualifies" })
  })

  // ── Condición: reduced-motion ────────────────────────────────────────────
  it("falls back to poster when prefers-reduced-motion is set", () => {
    const result = evaluateCapabilityGate(qualifyingSignals({ prefersReducedMotion: true }))
    expect(result).toEqual({ qualifies: false, reason: "reduced-motion" })
  })

  // ── Condición: sin WebGL ──────────────────────────────────────────────────
  it("falls back to poster when there is no WebGL context", () => {
    const result = evaluateCapabilityGate(qualifyingSignals({ hasWebGL: false }))
    expect(result).toEqual({ qualifies: false, reason: "no-webgl" })
  })

  // ── Condición: mobile (viewport pequeño + puntero coarse) ───────────────
  it("falls back to poster on a mobile-shaped device (small viewport + coarse pointer)", () => {
    const result = evaluateCapabilityGate(
      qualifyingSignals({ viewportWidth: 390, pointerCoarse: true }),
    )
    expect(result).toEqual({ qualifies: false, reason: "mobile-or-low-end" })
  })

  // ── Condición: gama baja por hardwareConcurrency ─────────────────────────
  it("falls back to poster when hardwareConcurrency is at/under the low-end threshold", () => {
    const result = evaluateCapabilityGate(
      qualifyingSignals({ hardwareConcurrency: LOW_END_HARDWARE_CONCURRENCY_MAX }),
    )
    expect(result).toEqual({ qualifies: false, reason: "mobile-or-low-end" })
  })

  // ── Condición: gama baja por deviceMemory ────────────────────────────────
  it("falls back to poster when deviceMemory is at/under the low-end threshold", () => {
    const result = evaluateCapabilityGate(
      qualifyingSignals({ deviceMemory: LOW_END_DEVICE_MEMORY_MAX_GB }),
    )
    expect(result).toEqual({ qualifies: false, reason: "mobile-or-low-end" })
  })

  // ── Condición: save-data ──────────────────────────────────────────────────
  it("falls back to poster when navigator.connection.saveData is true", () => {
    const result = evaluateCapabilityGate(qualifyingSignals({ saveData: true }))
    expect(result).toEqual({ qualifies: false, reason: "save-data" })
  })

  // ── Condición: conexión lenta (effectiveType 2g/slow-2g) ─────────────────
  it("falls back to poster on a slow connection (effectiveType 2g/slow-2g)", () => {
    const result = evaluateCapabilityGate(qualifyingSignals({ slowEffectiveType: true }))
    expect(result).toEqual({ qualifies: false, reason: "save-data" })
  })

  // ── TRIANGULATE: señales ausentes (API no soportada) NO descalifican ────
  // "Fallback conservador cuando no existan" (design.md D5) se interpreta como:
  // no usar una señal opcional no soportada por el browser (p. ej. Safari no
  // expone deviceMemory) para bloquear 3D — solo los umbrales conocidos lo hacen.
  it("does NOT disqualify when hardwareConcurrency/deviceMemory are unsupported (undefined)", () => {
    const result = evaluateCapabilityGate(
      qualifyingSignals({ hardwareConcurrency: undefined, deviceMemory: undefined }),
    )
    expect(result).toEqual({ qualifies: true, reason: "qualifies" })
  })

  // ── TRIANGULATE: prioridad — reduced-motion gana aunque haya más de una falla ──
  it("prioritizes reduced-motion as the reason when multiple conditions fail at once", () => {
    const result = evaluateCapabilityGate(
      qualifyingSignals({ prefersReducedMotion: true, hasWebGL: false, saveData: true }),
    )
    expect(result.reason).toBe("reduced-motion")
  })

  // ── TRIANGULATE: viewport angosto SIN puntero coarse (ventana desktop) no cuenta como mobile ──
  it("does not treat a narrow desktop window (no coarse pointer) as mobile", () => {
    const result = evaluateCapabilityGate(
      qualifyingSignals({ viewportWidth: 390, pointerCoarse: false }),
    )
    expect(result).toEqual({ qualifies: true, reason: "qualifies" })
  })

  // ── TRIANGULATE: umbral justo por encima no descalifica (boundary) ──────
  it("does not disqualify hardwareConcurrency just above the low-end threshold", () => {
    const result = evaluateCapabilityGate(
      qualifyingSignals({ hardwareConcurrency: LOW_END_HARDWARE_CONCURRENCY_MAX + 1 }),
    )
    expect(result).toEqual({ qualifies: true, reason: "qualifies" })
  })
})

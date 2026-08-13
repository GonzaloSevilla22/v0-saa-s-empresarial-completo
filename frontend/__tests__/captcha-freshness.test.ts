/**
 * Tests del helper puro de frescura de captcha — change captcha-token-freshness.
 *
 * `isTokenStale` e `isCaptchaError` son predicados puros (instantes inyectados,
 * sin timers). `submitWithFreshCaptcha` se ejercita con un handle falso
 * (`isStale`/`refresh` como `vi.fn()`), sin DOM.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import {
  CAPTCHA_MAX_TOKEN_AGE_MS,
  isTokenStale,
  isCaptchaError,
  submitWithFreshCaptcha,
  type CaptchaFreshnessHandle,
} from "@/lib/captcha-freshness"

describe("isTokenStale", () => {
  it("token recién emitido no está viejo", () => {
    const now = 1_000_000
    expect(isTokenStale(now, now)).toBe(false)
  })

  it("edad por encima del umbral -> true", () => {
    const mintedAt = 1_000_000
    const now = mintedAt + CAPTCHA_MAX_TOKEN_AGE_MS + 1
    expect(isTokenStale(mintedAt, now)).toBe(true)
  })

  it("mintedAt null -> false (no hay token emitido, nada que envejecer)", () => {
    expect(isTokenStale(null, 1_000_000)).toBe(false)
  })

  it("edad exactamente igual al umbral -> false (todavía no la superó)", () => {
    const mintedAt = 1_000_000
    const now = mintedAt + CAPTCHA_MAX_TOKEN_AGE_MS
    expect(isTokenStale(mintedAt, now)).toBe(false)
  })

  it("respeta un maxAgeMs explícito distinto del default", () => {
    const mintedAt = 1_000_000
    const now = mintedAt + 5_000
    expect(isTokenStale(mintedAt, now, 4_000)).toBe(true)
    expect(isTokenStale(mintedAt, now, 6_000)).toBe(false)
  })
})

describe("isCaptchaError", () => {
  it.each([
    ["captcha protection: request disallowed (timeout-or-duplicate)"],
    ["timeout-or-duplicate"],
    ["invalid-input-response"],
  ])("reconoce %s en un Error", (message) => {
    expect(isCaptchaError(new Error(message))).toBe(true)
  })

  it("reconoce el mensaje sobre un string suelto", () => {
    expect(isCaptchaError("captcha protection: request disallowed")).toBe(true)
  })

  it("reconoce el mensaje sobre un objeto con .message", () => {
    expect(isCaptchaError({ message: "invalid-input-response" })).toBe(true)
  })

  it("no reconoce credenciales inválidas", () => {
    expect(isCaptchaError(new Error("Invalid login credentials"))).toBe(false)
  })

  it("no reconoce un error de red", () => {
    expect(isCaptchaError(new Error("Failed to fetch"))).toBe(false)
  })

  it("no reconoce null ni undefined", () => {
    expect(isCaptchaError(null)).toBe(false)
    expect(isCaptchaError(undefined)).toBe(false)
  })
})

describe("submitWithFreshCaptcha", () => {
  function fakeHandle(overrides: Partial<CaptchaFreshnessHandle> = {}): CaptchaFreshnessHandle {
    return {
      isStale: vi.fn().mockReturnValue(false),
      refresh: vi.fn().mockResolvedValue("fresh-token"),
      ...overrides,
    }
  }

  it("token fresco -> run se llama una vez con el token original, sin refresh", async () => {
    const captcha = fakeHandle({ isStale: vi.fn().mockReturnValue(false) })
    const run = vi.fn().mockResolvedValue("ok")

    const result = await submitWithFreshCaptcha({ captcha, token: "original-token", run })

    expect(result).toBe("ok")
    expect(run).toHaveBeenCalledTimes(1)
    expect(run).toHaveBeenCalledWith("original-token")
    expect(captcha.refresh).not.toHaveBeenCalled()
  })

  it("token viejo -> refresh primero, run recibe el token nuevo (nunca el viejo)", async () => {
    const captcha = fakeHandle({
      isStale: vi.fn().mockReturnValue(true),
      refresh: vi.fn().mockResolvedValue("renewed-token"),
    })
    const run = vi.fn().mockResolvedValue("ok")

    await submitWithFreshCaptcha({ captcha, token: "stale-token", run })

    expect(captcha.refresh).toHaveBeenCalledTimes(1)
    expect(run).toHaveBeenCalledTimes(1)
    expect(run).toHaveBeenCalledWith("renewed-token")
  })

  it("run falla con error de captcha -> refresh + exactamente un reintento con token fresco", async () => {
    const captcha = fakeHandle({
      isStale: vi.fn().mockReturnValue(false),
      refresh: vi.fn().mockResolvedValue("retry-token"),
    })
    const run = vi
      .fn()
      .mockRejectedValueOnce(new Error("captcha protection: request disallowed"))
      .mockResolvedValueOnce("ok-on-retry")

    const result = await submitWithFreshCaptcha({ captcha, token: "first-token", run })

    expect(result).toBe("ok-on-retry")
    expect(run).toHaveBeenCalledTimes(2)
    expect(run).toHaveBeenNthCalledWith(1, "first-token")
    expect(run).toHaveBeenNthCalledWith(2, "retry-token")
    expect(captcha.refresh).toHaveBeenCalledTimes(1)
  })

  it("(guarda a) error de captcha en ambos intentos -> run llamado 2 veces, se propaga el error del 2º", async () => {
    const captcha = fakeHandle({
      isStale: vi.fn().mockReturnValue(false),
      refresh: vi.fn().mockResolvedValue("retry-token"),
    })
    const secondError = new Error("timeout-or-duplicate")
    const run = vi
      .fn()
      .mockRejectedValueOnce(new Error("captcha protection: request disallowed"))
      .mockRejectedValueOnce(secondError)

    await expect(submitWithFreshCaptcha({ captcha, token: "t", run })).rejects.toThrow(secondError)
    expect(run).toHaveBeenCalledTimes(2)
    expect(captcha.refresh).toHaveBeenCalledTimes(1)
  })

  it("(guarda b) error que no es de captcha -> run llamado 1 sola vez, se propaga tal cual", async () => {
    const captcha = fakeHandle()
    const notCaptchaError = new Error("Invalid login credentials")
    const run = vi.fn().mockRejectedValue(notCaptchaError)

    await expect(submitWithFreshCaptcha({ captcha, token: "t", run })).rejects.toThrow(notCaptchaError)
    expect(run).toHaveBeenCalledTimes(1)
    expect(captcha.refresh).not.toHaveBeenCalled()
  })

  it("(guarda c) refresh() rechaza (timeout) -> se propaga sin más intentos", async () => {
    const timeoutError = new Error("captcha refresh timed out")
    const captcha = fakeHandle({
      isStale: vi.fn().mockReturnValue(true),
      refresh: vi.fn().mockRejectedValue(timeoutError),
    })
    const run = vi.fn()

    await expect(submitWithFreshCaptcha({ captcha, token: "t", run })).rejects.toThrow(timeoutError)
    expect(run).not.toHaveBeenCalled()
  })

  it("(guarda d) captcha nulo -> no rompe, se ejecuta run con el token que haya", async () => {
    const run = vi.fn().mockResolvedValue("ok")

    const result = await submitWithFreshCaptcha({ captcha: null, token: "whatever-token", run })

    expect(result).toBe("ok")
    expect(run).toHaveBeenCalledWith("whatever-token")
  })

  it("(guarda d bis) captcha nulo + error de captcha -> no reintenta (no hay refresh posible)", async () => {
    const captchaError = new Error("captcha protection: request disallowed")
    const run = vi.fn().mockRejectedValue(captchaError)

    await expect(submitWithFreshCaptcha({ captcha: null, token: "t", run })).rejects.toThrow(captchaError)
    expect(run).toHaveBeenCalledTimes(1)
  })
})

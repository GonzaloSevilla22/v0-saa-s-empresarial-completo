/**
 * Tests del hook `useCaptchaGate` (frontend/hooks/auth/use-captcha-gate.ts)
 * — change captcha-renewal-feedback. Es el pegamento (D5 en design.md) entre
 * el reducer puro de `lib/captcha-freshness.ts` y las 4 pantallas de auth:
 * expone `captchaProps` para cablear al `CaptchaWidget`, `submitButtonProps`
 * para el botón de submit, y `submit(run)` para encolar/disparar el envío a
 * través de `submitWithFreshCaptcha`.
 *
 * No se monta un `CaptchaWidget` real acá: `captchaProps.onVerify/onExpire/
 * onError` se disparan directo desde el test (son los mismos callbacks que
 * el widget invoca), y `captchaRef.current` se deja `null` — igual que en
 * los tests de las 4 pantallas, `submitWithFreshCaptcha` con `captcha: null`
 * degrada a no reintentar (guarda d, ya cubierta en captcha-freshness.test.ts).
 *
 * Fake timers de vitest para el vencimiento de la cola (D8): ninguna
 * aserción usa `new Date()` sin argumento.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { renderHook, act, waitFor } from "@testing-library/react"
import { useCaptchaGate } from "@/hooks/auth/use-captcha-gate"
import { CAPTCHA_RENEWAL_LABEL, CAPTCHA_REFRESH_TIMEOUT_MS, CAPTCHA_RENEWAL_FAILED_MESSAGE } from "@/lib/captcha-freshness"

afterEach(() => {
  vi.useRealTimers()
})

describe("useCaptchaGate — al montar (arranque en frío)", () => {
  it("expone fase 'cold', disabled real, sin aria-disabled y sin statusMessage", () => {
    const { result } = renderHook(() => useCaptchaGate())

    expect(result.current.phase).toBe("cold")
    expect(result.current.submitButtonProps.disabled).toBe(true)
    expect(result.current.submitButtonProps["aria-disabled"]).toBeUndefined()
    expect(result.current.statusMessage).toBe("")
    expect(result.current.isRenewing).toBe(false)
    expect(result.current.isLoading).toBe(false)
    expect(result.current.token).toBe("")
  })
})

describe("useCaptchaGate — token emitido / perdido", () => {
  it("onVerify -> fase 'ready', botón habilitado", () => {
    const { result } = renderHook(() => useCaptchaGate())

    act(() => result.current.captchaProps.onVerify("token-a"))

    expect(result.current.phase).toBe("ready")
    expect(result.current.token).toBe("token-a")
    expect(result.current.submitButtonProps.disabled).toBe(false)
    expect(result.current.submitButtonProps["aria-disabled"]).toBeUndefined()
  })

  it("(triangulate) onExpire tras un token -> 'renewing', aria-disabled y statusMessage no vacío", () => {
    const { result } = renderHook(() => useCaptchaGate())

    act(() => result.current.captchaProps.onVerify("token-b"))
    act(() => result.current.captchaProps.onExpire())

    expect(result.current.phase).toBe("renewing")
    expect(result.current.isRenewing).toBe(true)
    expect(result.current.submitButtonProps.disabled).toBe(false)
    expect(result.current.submitButtonProps["aria-disabled"]).toBe(true)
    expect(result.current.statusMessage).toBe(CAPTCHA_RENEWAL_LABEL)
    expect(result.current.token).toBe("")
  })

  it("(triangulate) onError tras un token -> 'renewing'", () => {
    const { result } = renderHook(() => useCaptchaGate())

    act(() => result.current.captchaProps.onVerify("token-c"))
    act(() => result.current.captchaProps.onError())

    expect(result.current.phase).toBe("renewing")
    expect(result.current.isRenewing).toBe(true)
  })
})

describe("useCaptchaGate — submit(run) en fase 'ready'", () => {
  it("(triangulate) delega en submitWithFreshCaptcha y expone isLoading mientras corre", async () => {
    const { result } = renderHook(() => useCaptchaGate())
    act(() => result.current.captchaProps.onVerify("token-ready"))

    let resolveRun: (value: string) => void = () => {}
    const run = vi.fn().mockImplementation(
      () =>
        new Promise<string>((resolve) => {
          resolveRun = resolve
        }),
    )

    let submitPromise: Promise<string> | undefined
    act(() => {
      submitPromise = result.current.submit(run)
    })

    expect(run).toHaveBeenCalledWith("token-ready")
    expect(result.current.isLoading).toBe(true)

    await act(async () => {
      resolveRun("ok")
      await submitPromise
    })

    expect(result.current.isLoading).toBe(false)
    await expect(submitPromise).resolves.toBe("ok")
  })

  it("(triangulate) el catch resetea el widget, limpia el token y deja la fase en 'renewing' (D2/D4.6)", async () => {
    const { result } = renderHook(() => useCaptchaGate())
    const resetMock = vi.fn()
    act(() => result.current.captchaProps.onVerify("token-fail"))
    // Handle falso del widget vía el ref que expone el hook — refresh no se
    // ejercita acá porque el error no matchea el patrón de captcha.
    result.current.captchaRef.current = { reset: resetMock, isStale: () => false, refresh: vi.fn() }

    const run = vi.fn().mockRejectedValue(new Error("Invalid login credentials"))

    let submitPromise: Promise<unknown> | undefined
    await act(async () => {
      submitPromise = result.current.submit(run)
      await submitPromise.catch(() => {})
    })

    await expect(submitPromise).rejects.toThrow("Invalid login credentials")
    expect(resetMock).toHaveBeenCalledTimes(1)
    expect(result.current.token).toBe("")
    expect(result.current.phase).toBe("renewing")
    expect(result.current.isLoading).toBe(false)
  })
})

describe("useCaptchaGate — cola de submit durante la renovación", () => {
  function renewingHook() {
    const rendered = renderHook(() => useCaptchaGate())
    act(() => rendered.result.current.captchaProps.onVerify("token-initial"))
    act(() => rendered.result.current.captchaProps.onExpire())
    return rendered
  }

  it("click en 'renewing' no llama a run; al emitirse el token fresco, run se llama exactamente una vez", async () => {
    const { result } = renewingHook()
    const run = vi.fn().mockResolvedValue("queued-ok")

    let submitPromise: Promise<string> | undefined
    act(() => {
      submitPromise = result.current.submit(run)
    })

    expect(run).not.toHaveBeenCalled()
    expect(result.current.phase).toBe("queued")
    expect(result.current.submitButtonProps["aria-disabled"]).toBe(true)

    await act(async () => {
      result.current.captchaProps.onVerify("token-fresh")
      await submitPromise
    })

    expect(run).toHaveBeenCalledTimes(1)
    expect(run).toHaveBeenCalledWith("token-fresh")
    await expect(submitPromise).resolves.toBe("queued-ok")
    expect(result.current.phase).toBe("ready")
  })

  it("(triangulate) dos tokens seguidos tras encolar ⇒ un solo run", async () => {
    const { result } = renewingHook()
    const run = vi.fn().mockResolvedValue("ok")

    act(() => {
      result.current.submit(run)
    })
    expect(result.current.phase).toBe("queued")

    await act(async () => {
      result.current.captchaProps.onVerify("token-1")
      result.current.captchaProps.onVerify("token-2")
    })

    await waitFor(() => expect(run).toHaveBeenCalledTimes(1))
    expect(run).toHaveBeenCalledWith("token-1")
  })

  it("(triangulate) clicks repetidos en 'renewing'/'queued' ⇒ un solo run al llegar el token", async () => {
    const { result } = renewingHook()
    const run = vi.fn().mockResolvedValue("ok")

    act(() => {
      result.current.submit(run)
    })
    act(() => {
      result.current.submit(vi.fn().mockResolvedValue("ignored"))
    })
    act(() => {
      result.current.submit(vi.fn().mockResolvedValue("ignored-2"))
    })
    expect(result.current.phase).toBe("queued")

    await act(async () => {
      result.current.captchaProps.onVerify("token-once")
    })

    await waitFor(() => expect(run).toHaveBeenCalledTimes(1))
    expect(run).toHaveBeenCalledWith("token-once")
  })

  it("(triangulate) vencimiento: sin token dentro de CAPTCHA_REFRESH_TIMEOUT_MS ⇒ run nunca se llama, error surfaceado, fase vuelve a 'renewing'", async () => {
    vi.useFakeTimers()
    const { result } = renewingHook()
    const run = vi.fn().mockResolvedValue("ok")

    let submitPromise: Promise<string> | undefined
    act(() => {
      submitPromise = result.current.submit(run)
    })
    expect(result.current.phase).toBe("queued")

    const assertion = expect(submitPromise).rejects.toThrow(CAPTCHA_RENEWAL_FAILED_MESSAGE)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(CAPTCHA_REFRESH_TIMEOUT_MS + 1)
    })
    await assertion

    expect(run).not.toHaveBeenCalled()
    expect(result.current.phase).toBe("renewing")

    // Un token que llega después del vencimiento no dispara nada (la cola ya se descartó).
    act(() => result.current.captchaProps.onVerify("token-too-late"))
    expect(run).not.toHaveBeenCalled()
    expect(result.current.phase).toBe("ready")
  })

  it("(triangulate) onError con cola pendiente ⇒ cola abortada y error surfaceado sin esperar el timeout", async () => {
    vi.useFakeTimers()
    const { result } = renewingHook()
    const run = vi.fn().mockResolvedValue("ok")

    let submitPromise: Promise<string> | undefined
    act(() => {
      submitPromise = result.current.submit(run)
    })
    expect(result.current.phase).toBe("queued")

    const assertion = expect(submitPromise).rejects.toThrow(CAPTCHA_RENEWAL_FAILED_MESSAGE)
    act(() => result.current.captchaProps.onError())
    await assertion

    expect(run).not.toHaveBeenCalled()
    expect(result.current.phase).toBe("renewing")

    // No hace falta esperar el timeout completo: si lo avanzamos, no pasa nada más.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(CAPTCHA_REFRESH_TIMEOUT_MS + 1)
    })
    expect(run).not.toHaveBeenCalled()
  })

  it("(triangulate) onExpire con cola pendiente ⇒ la cola se mantiene viva", async () => {
    const { result } = renewingHook()
    const run = vi.fn().mockResolvedValue("ok")

    let submitPromise: Promise<string> | undefined
    act(() => {
      submitPromise = result.current.submit(run)
    })
    expect(result.current.phase).toBe("queued")

    act(() => result.current.captchaProps.onExpire())
    expect(result.current.phase).toBe("queued")
    expect(run).not.toHaveBeenCalled()

    await act(async () => {
      result.current.captchaProps.onVerify("token-after-second-expire")
      await submitPromise
    })

    expect(run).toHaveBeenCalledTimes(1)
    expect(run).toHaveBeenCalledWith("token-after-second-expire")
  })
})

describe("useCaptchaGate — anti-doble-submit", () => {
  it("click con submit en vuelo no encola ni dispara un segundo run", async () => {
    const { result } = renderHook(() => useCaptchaGate())
    act(() => result.current.captchaProps.onVerify("token-inflight"))

    let resolveRun: (value: string) => void = () => {}
    const run = vi.fn().mockImplementation(
      () =>
        new Promise<string>((resolve) => {
          resolveRun = resolve
        }),
    )

    act(() => {
      result.current.submit(run)
    })
    expect(result.current.isLoading).toBe(true)
    expect(result.current.submitButtonProps.disabled).toBe(true)

    const secondRun = vi.fn().mockResolvedValue("second")
    act(() => {
      result.current.submit(secondRun)
    })

    expect(secondRun).not.toHaveBeenCalled()
    expect(run).toHaveBeenCalledTimes(1)

    await act(async () => {
      resolveRun("ok")
    })
  })
})

describe("useCaptchaGate — desmontaje con cola pendiente", () => {
  it("el timer de la cola se limpia y no se dispara ningún submit tras unmount", async () => {
    vi.useFakeTimers()
    const { result, unmount } = renderHook(() => useCaptchaGate())
    act(() => result.current.captchaProps.onVerify("token-unmount"))
    act(() => result.current.captchaProps.onExpire())

    const run = vi.fn().mockResolvedValue("ok")
    act(() => {
      result.current.submit(run)
    })
    expect(result.current.phase).toBe("queued")

    unmount()

    await act(async () => {
      await vi.advanceTimersByTimeAsync(CAPTCHA_REFRESH_TIMEOUT_MS + 1_000)
    })

    expect(run).not.toHaveBeenCalled()
  })
})

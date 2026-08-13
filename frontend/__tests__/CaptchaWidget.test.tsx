import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { act, cleanup, render, screen, waitFor } from "@testing-library/react"
import { createRef, forwardRef, useImperativeHandle } from "react"

import { CaptchaWidget, type CaptchaWidgetHandle } from "@/components/auth/CaptchaWidget"
import { CAPTCHA_MAX_TOKEN_AGE_MS, CaptchaRefreshTimeoutError } from "@/lib/captcha-freshness"

interface MockTurnstileProps {
  onSuccess?: (token: string) => void
  onExpire?: () => void
  onError?: () => void
}

interface MockTurnstileHandle {
  reset: () => void
}

// Mock capaz de disparar onSuccess/onExpire/onError a demanda desde el test,
// para ejercitar mintedAt/isStale()/refresh() y el auto-reset por visibilidad
// (change captcha-token-freshness). vi.hoisted: el mock se referencia desde
// fuera de la factory de vi.mock, así que necesita vivir fuera del TDZ.
const turnstile = vi.hoisted(() => {
  let handlers: MockTurnstileProps = {}
  return {
    setHandlers(next: MockTurnstileProps) {
      handlers = next
    },
    fireSuccess(token: string) {
      handlers.onSuccess?.(token)
    },
    fireExpire() {
      handlers.onExpire?.()
    },
    fireError() {
      handlers.onError?.()
    },
    resetMock: vi.fn(),
  }
})

vi.mock("@marsidev/react-turnstile", () => ({
  Turnstile: forwardRef<MockTurnstileHandle, MockTurnstileProps>((props, ref) => {
    turnstile.setHandlers(props)
    useImperativeHandle(ref, () => ({ reset: turnstile.resetMock }), [])
    return <div data-testid="turnstile-widget" />
  }),
}))

function setVisibilityState(state: DocumentVisibilityState) {
  Object.defineProperty(document, "visibilityState", { value: state, configurable: true })
}

function dispatchVisibilityChange() {
  document.dispatchEvent(new Event("visibilitychange"))
}

beforeEach(() => {
  turnstile.setHandlers({})
  turnstile.resetMock.mockClear()
  setVisibilityState("visible")
})

afterEach(() => {
  cleanup()
  vi.unstubAllEnvs()
  vi.useRealTimers()
})

describe("CaptchaWidget — stub local de Playwright", () => {
  it("resuelve sin red únicamente cuando el flag QA está activo en localhost", async () => {
    vi.stubEnv("NEXT_PUBLIC_PLAYWRIGHT_LOCAL", "true")
    const onVerify = vi.fn()

    render(<CaptchaWidget onVerify={onVerify} />)

    await waitFor(() => {
      expect(onVerify).toHaveBeenCalledWith("playwright-local-captcha-stub")
    })
    expect(screen.getByTestId("captcha-local-stub")).toBeInTheDocument()
    expect(screen.queryByTestId("turnstile-widget")).not.toBeInTheDocument()
  })

  it("mantiene el formulario cerrado cuando el flag QA no está activo", () => {
    vi.stubEnv("NEXT_PUBLIC_PLAYWRIGHT_LOCAL", "false")
    vi.stubEnv("NEXT_PUBLIC_TURNSTILE_SITE_KEY", "")
    const onVerify = vi.fn()

    render(<CaptchaWidget onVerify={onVerify} />)

    expect(onVerify).not.toHaveBeenCalled()
    expect(screen.getByRole("note")).toBeInTheDocument()
  })

  it("ignora el bypass en un build de producción", () => {
    vi.stubEnv("NODE_ENV", "production")
    vi.stubEnv("NEXT_PUBLIC_PLAYWRIGHT_LOCAL", "true")
    vi.stubEnv("NEXT_PUBLIC_TURNSTILE_SITE_KEY", "turnstile-public-test-key")
    const onVerify = vi.fn()

    render(<CaptchaWidget onVerify={onVerify} />)

    expect(onVerify).not.toHaveBeenCalled()
    expect(screen.getByTestId("turnstile-widget")).toBeInTheDocument()
  })
})

function renderRealWidget(onExpire = vi.fn()) {
  vi.stubEnv("NEXT_PUBLIC_PLAYWRIGHT_LOCAL", "false")
  vi.stubEnv("NEXT_PUBLIC_TURNSTILE_SITE_KEY", "turnstile-public-test-key")
  const onVerify = vi.fn()
  const ref = createRef<CaptchaWidgetHandle>()
  render(<CaptchaWidget ref={ref} onVerify={onVerify} onExpire={onExpire} />)
  return { ref, onVerify, onExpire }
}

describe("CaptchaWidget — mintedAt / isStale() / refresh()", () => {
  it("sin token emitido, isStale() es false", () => {
    const { ref } = renderRealWidget()
    expect(ref.current!.isStale()).toBe(false)
  })

  it("token recién emitido no está viejo; tras superar el umbral, sí", () => {
    vi.useFakeTimers()
    vi.setSystemTime(1_000_000)
    const { ref, onVerify } = renderRealWidget()

    act(() => turnstile.fireSuccess("token-a"))
    expect(onVerify).toHaveBeenCalledWith("token-a")
    expect(ref.current!.isStale()).toBe(false)

    vi.setSystemTime(1_000_000 + CAPTCHA_MAX_TOKEN_AGE_MS + 1)
    expect(ref.current!.isStale()).toBe(true)
  })

  it("(triangulate) tras reset(), mintedAt se limpia y isStale() vuelve a false", () => {
    vi.useFakeTimers()
    vi.setSystemTime(1_000_000)
    const { ref } = renderRealWidget()

    act(() => turnstile.fireSuccess("token-b"))
    vi.setSystemTime(1_000_000 + CAPTCHA_MAX_TOKEN_AGE_MS + 1)
    expect(ref.current!.isStale()).toBe(true)

    act(() => ref.current!.reset())
    expect(turnstile.resetMock).toHaveBeenCalledTimes(1)
    expect(ref.current!.isStale()).toBe(false)
  })

  it("(triangulate) tras onExpire/onError del widget real, isStale() vuelve a false", () => {
    vi.useFakeTimers()
    vi.setSystemTime(1_000_000)
    const { ref } = renderRealWidget()

    act(() => turnstile.fireSuccess("token-c"))
    vi.setSystemTime(1_000_000 + CAPTCHA_MAX_TOKEN_AGE_MS + 1)
    expect(ref.current!.isStale()).toBe(true)

    act(() => turnstile.fireExpire())
    expect(ref.current!.isStale()).toBe(false)

    act(() => turnstile.fireSuccess("token-d"))
    vi.setSystemTime(1_000_000 + 2 * (CAPTCHA_MAX_TOKEN_AGE_MS + 1))
    expect(ref.current!.isStale()).toBe(true)
    act(() => turnstile.fireError())
    expect(ref.current!.isStale()).toBe(false)
  })

  it("refresh() resetea el widget y resuelve con el próximo token emitido", async () => {
    const { ref } = renderRealWidget()

    const pending = ref.current!.refresh()
    expect(turnstile.resetMock).toHaveBeenCalledTimes(1)

    act(() => turnstile.fireSuccess("refreshed-token"))
    await expect(pending).resolves.toBe("refreshed-token")
    expect(ref.current!.isStale()).toBe(false)
  })

  it("(triangulate a) dos refresh() concurrentes se resuelven con un mismo onSuccess", async () => {
    const { ref } = renderRealWidget()

    const first = ref.current!.refresh()
    const second = ref.current!.refresh()

    act(() => turnstile.fireSuccess("shared-token"))

    await expect(first).resolves.toBe("shared-token")
    await expect(second).resolves.toBe("shared-token")
  })

  it("(triangulate b) sin token dentro del timeout, refresh() rechaza con CaptchaRefreshTimeoutError", async () => {
    vi.useFakeTimers()
    const { ref } = renderRealWidget()

    const pending = ref.current!.refresh(50)
    const assertion = expect(pending).rejects.toBeInstanceOf(CaptchaRefreshTimeoutError)
    await vi.advanceTimersByTimeAsync(60)
    await assertion
  })
})

describe("CaptchaWidget — auto-renovación por visibilidad", () => {
  it("token viejo + vuelta a visible -> reset del widget y notificación al consumidor (onExpire)", () => {
    vi.useFakeTimers()
    vi.setSystemTime(1_000_000)
    const { ref, onExpire } = renderRealWidget()

    act(() => turnstile.fireSuccess("token-stale"))
    vi.setSystemTime(1_000_000 + CAPTCHA_MAX_TOKEN_AGE_MS + 1)

    setVisibilityState("visible")
    act(() => dispatchVisibilityChange())

    expect(turnstile.resetMock).toHaveBeenCalledTimes(1)
    expect(onExpire).toHaveBeenCalledTimes(1)
    expect(ref.current!.isStale()).toBe(false)
  })

  it("(triangulate a) token fresco + vuelta a visible -> no hay reset ni notificación", () => {
    vi.useFakeTimers()
    vi.setSystemTime(1_000_000)
    const { onExpire } = renderRealWidget()

    act(() => turnstile.fireSuccess("token-fresh"))
    vi.setSystemTime(1_000_000 + 1_000) // muy por debajo del umbral

    setVisibilityState("visible")
    act(() => dispatchVisibilityChange())

    expect(turnstile.resetMock).not.toHaveBeenCalled()
    expect(onExpire).not.toHaveBeenCalled()
  })

  it("(triangulate b) sin token emitido, el cambio de visibilidad es inerte", () => {
    const { onExpire } = renderRealWidget()

    setVisibilityState("visible")
    act(() => dispatchVisibilityChange())

    expect(turnstile.resetMock).not.toHaveBeenCalled()
    expect(onExpire).not.toHaveBeenCalled()
  })

  it("(triangulate c) dos visibilitychange seguidos con el token ya invalidado -> un solo reset", () => {
    vi.useFakeTimers()
    vi.setSystemTime(1_000_000)
    const { onExpire } = renderRealWidget()

    act(() => turnstile.fireSuccess("token-stale-2"))
    vi.setSystemTime(1_000_000 + CAPTCHA_MAX_TOKEN_AGE_MS + 1)

    setVisibilityState("visible")
    act(() => dispatchVisibilityChange())
    act(() => dispatchVisibilityChange())

    expect(turnstile.resetMock).toHaveBeenCalledTimes(1)
    expect(onExpire).toHaveBeenCalledTimes(1)
  })

  it("(triangulate d) tras unmount, el listener se remueve — un visibilitychange posterior no llama a nada", () => {
    vi.useFakeTimers()
    vi.setSystemTime(1_000_000)
    const onExpire = vi.fn()
    const { unmount } = (() => {
      vi.stubEnv("NEXT_PUBLIC_PLAYWRIGHT_LOCAL", "false")
      vi.stubEnv("NEXT_PUBLIC_TURNSTILE_SITE_KEY", "turnstile-public-test-key")
      return render(<CaptchaWidget onVerify={vi.fn()} onExpire={onExpire} />)
    })()

    act(() => turnstile.fireSuccess("token-e"))
    vi.setSystemTime(1_000_000 + CAPTCHA_MAX_TOKEN_AGE_MS + 1)

    unmount()

    setVisibilityState("visible")
    expect(() => dispatchVisibilityChange()).not.toThrow()
    expect(turnstile.resetMock).not.toHaveBeenCalled()
    expect(onExpire).not.toHaveBeenCalled()
  })
})

describe("CaptchaWidget — exención de frescura en el stub de Playwright (D5)", () => {
  function renderStub() {
    vi.stubEnv("NEXT_PUBLIC_PLAYWRIGHT_LOCAL", "true")
    const ref = createRef<CaptchaWidgetHandle>()
    render(<CaptchaWidget ref={ref} onVerify={vi.fn()} />)
    return ref
  }

  it("isStale() es siempre false, por más que avance el reloj", () => {
    vi.useFakeTimers()
    vi.setSystemTime(1_000_000)
    const ref = renderStub()

    expect(ref.current!.isStale()).toBe(false)
    vi.setSystemTime(1_000_000 + CAPTCHA_MAX_TOKEN_AGE_MS * 10)
    expect(ref.current!.isStale()).toBe(false)
  })

  it("refresh() resuelve inmediato con el token del stub (nunca cuelga)", async () => {
    const ref = renderStub()

    await expect(ref.current!.refresh()).resolves.toBe("playwright-local-captcha-stub")
  })

  it("no registra el listener de visibilitychange", async () => {
    const addEventListenerSpy = vi.spyOn(document, "addEventListener")
    renderStub()

    await waitFor(() => {
      expect(screen.getByTestId("captcha-local-stub")).toBeInTheDocument()
    })

    const visibilityCalls = addEventListenerSpy.mock.calls.filter(([eventName]) => eventName === "visibilitychange")
    expect(visibilityCalls).toHaveLength(0)
    addEventListenerSpy.mockRestore()
  })
})

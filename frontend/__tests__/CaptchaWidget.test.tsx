import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { act, cleanup, render, screen, waitFor } from "@testing-library/react"
import { createRef, forwardRef, useImperativeHandle } from "react"

import { CaptchaWidget, type CaptchaWidgetHandle } from "@/components/auth/CaptchaWidget"
import { CAPTCHA_MAX_TOKEN_AGE_MS, CaptchaRefreshTimeoutError } from "@/lib/captcha-freshness"

interface MockTurnstileProps {
  onSuccess?: (token: string) => void
  onExpire?: () => void
  onError?: () => void
  options?: { size?: string }
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
    /** Cada `size` con el que se llegó a montar Turnstile, en orden. */
    sizesSeen: [] as Array<string | undefined>,
  }
})

vi.mock("@marsidev/react-turnstile", () => ({
  Turnstile: forwardRef<MockTurnstileHandle, MockTurnstileProps>((props, ref) => {
    turnstile.setHandlers(props)
    turnstile.sizesSeen.push(props.options?.size)
    useImperativeHandle(ref, () => ({ reset: turnstile.resetMock }), [])
    return <div data-testid="turnstile-widget" data-size={props.options?.size} />
  }),
}))

/**
 * jsdom no hace layout: `clientWidth` es siempre 0. Para ejercitar la elección
 * de tamaño se fija el ancho que "mediría" el slot. Se restaura en afterEach.
 */
const originalClientWidth = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "clientWidth")

function stubSlotClientWidth(widthPx: number) {
  Object.defineProperty(HTMLElement.prototype, "clientWidth", {
    configurable: true,
    get() {
      return widthPx
    },
  })
}

function restoreClientWidth() {
  if (originalClientWidth) {
    Object.defineProperty(HTMLElement.prototype, "clientWidth", originalClientWidth)
  }
}

function setVisibilityState(state: DocumentVisibilityState) {
  Object.defineProperty(document, "visibilityState", { value: state, configurable: true })
}

function dispatchVisibilityChange() {
  document.dispatchEvent(new Event("visibilitychange"))
}

beforeEach(() => {
  turnstile.setHandlers({})
  turnstile.resetMock.mockClear()
  turnstile.sizesSeen.length = 0
  setVisibilityState("visible")
})

afterEach(() => {
  cleanup()
  vi.unstubAllEnvs()
  vi.useRealTimers()
  restoreClientWidth()
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

/**
 * fix/captcha-widget-mobile-overflow.
 *
 * En un teléfono de 360 px la columna de las pantallas de auth mide 294,4 px
 * y Turnstile `flexible` exige 300: la librería fuerza su contenedor a 300 px
 * alineado a la IZQUIERDA, así que el widget sobresalía 5,6 px sólo por la
 * derecha (medido en navegador real). El slot centra ese desborde y, cuando
 * ni así entra, elige `compact`.
 *
 * jsdom no hace layout, así que acá se fija la ESTRUCTURA y la decisión de
 * tamaño; el ancho real lo verifica `e2e/harness/captcha-slot-mobile.spec.ts`.
 */
describe("CaptchaWidget — slot de ancho (móvil)", () => {
  function renderReal(props: { className?: string } = {}) {
    vi.stubEnv("NEXT_PUBLIC_PLAYWRIGHT_LOCAL", "false")
    vi.stubEnv("NEXT_PUBLIC_TURNSTILE_SITE_KEY", "turnstile-public-test-key")
    return render(<CaptchaWidget onVerify={vi.fn()} {...props} />)
  }

  it("monta Turnstile dentro de un marco, dentro del slot, en flexible a 360 px", () => {
    stubSlotClientWidth(294)
    renderReal()

    const slot = screen.getByTestId("captcha-slot")
    const frame = screen.getByTestId("captcha-frame")
    const widget = screen.getByTestId("turnstile-widget")

    expect(slot).toContainElement(frame)
    expect(frame).toContainElement(widget)
    expect(slot).toHaveAttribute("data-captcha-size", "flexible")
    expect(widget).toHaveAttribute("data-size", "flexible")
  })

  it("elige compact cuando la columna es demasiado angosta (viewport de 320 px)", () => {
    stubSlotClientWidth(254)
    renderReal()

    expect(screen.getByTestId("captcha-slot")).toHaveAttribute("data-captcha-size", "compact")
    expect(screen.getByTestId("turnstile-widget")).toHaveAttribute("data-size", "compact")
  })

  it("nunca monta Turnstile con un tamaño y después con otro (re-renderizar el widget tira el challenge)", () => {
    stubSlotClientWidth(254)
    renderReal()

    expect(new Set(turnstile.sizesSeen)).toEqual(new Set(["compact"]))
  })

  it("sigue aplicando el className del consumidor al slot", () => {
    stubSlotClientWidth(400)
    renderReal({ className: "mt-2" })

    expect(screen.getByTestId("captcha-slot")).toHaveClass("mt-2")
  })

  it("el stub de Playwright ocupa el MISMO slot y marco que el widget real — no queda ciego al layout", async () => {
    stubSlotClientWidth(294)
    renderReal()
    const realSlotClass = screen.getByTestId("captcha-slot").className
    const realFrameClass = screen.getByTestId("captcha-frame").className
    cleanup()
    vi.unstubAllEnvs()

    vi.stubEnv("NEXT_PUBLIC_PLAYWRIGHT_LOCAL", "true")
    render(<CaptchaWidget onVerify={vi.fn()} />)
    await waitFor(() => {
      expect(screen.getByTestId("captcha-local-stub")).toBeInTheDocument()
    })

    const stubSlot = screen.getByTestId("captcha-slot")
    const stubFrame = screen.getByTestId("captcha-frame")
    expect(stubFrame).toContainElement(screen.getByTestId("captcha-local-stub"))
    expect(stubSlot.className).toBe(realSlotClass)
    expect(stubFrame.className).toBe(realFrameClass)
    expect(stubSlot).toHaveAttribute("data-captcha-size", "flexible")
  })

  it("el stub también publica compact cuando la columna es angosta", async () => {
    stubSlotClientWidth(254)
    vi.stubEnv("NEXT_PUBLIC_PLAYWRIGHT_LOCAL", "true")
    render(<CaptchaWidget onVerify={vi.fn()} />)

    await waitFor(() => {
      expect(screen.getByTestId("captcha-slot")).toHaveAttribute("data-captcha-size", "compact")
    })
  })
})

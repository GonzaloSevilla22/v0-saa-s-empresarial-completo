/**
 * auth-hardening-jwt-cookies — D7, task 14.10.
 *
 * La task 14.7 introduce `reason=expired`: cuando una llamada al backend
 * responde 401 y no hay sesión, la app navega a
 * `/auth/login?reason=expired&next=…`. La pantalla de login sólo contemplaba
 * `reason === "idle"` (`app/auth/login/page.tsx:32-33`), así que ese motivo
 * llegaba **sin ningún mensaje**: el usuario quedaba frente a un formulario que
 * no pidió, sin saber por qué.
 *
 * Es superficie visible al usuario: entra por la regla del PO del 2026-08-02.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"

const loginMock = vi.fn()
const pushMock = vi.fn()

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ login: loginMock }),
}))

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: pushMock }),
  useSearchParams: vi.fn(),
}))

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), info: vi.fn() },
}))

vi.mock("next/link", () => ({
  default: ({ children, href }: { children: React.ReactNode; href: string }) => (
    <a href={href}>{children}</a>
  ),
}))

vi.mock("@/components/auth/MagicLinkForm", () => ({
  MagicLinkForm: () => <div data-testid="magic-link-form" />,
}))

/**
 * Doble de la compuerta de captcha: `submit(run)` corre `run` con un token
 * fresco, que es lo único que este archivo necesita para llegar a la
 * navegación posterior al login. El ciclo real de renovación lo cubren los
 * tests de `captcha-freshness`.
 */
vi.mock("@/hooks/auth", () => ({
  useCaptchaGate: () => ({
    captchaRef: { current: null },
    captchaProps: { onVerify: () => {}, onExpire: () => {}, onError: () => {} },
    token: "captcha-token",
    phase: "ready",
    isRenewing: false,
    isLoading: false,
    submitButtonProps: { disabled: false },
    statusMessage: "",
    submit: <T,>(run: (token: string) => Promise<T>) => run("captcha-token"),
  }),
}))

import { useSearchParams } from "next/navigation"
import LoginPage from "@/app/auth/login/page"

function withParams(params: Record<string, string>) {
  vi.mocked(useSearchParams).mockReturnValue({
    get: (key: string) => params[key] ?? null,
  } as ReturnType<typeof useSearchParams>)
}

const EXPIRED = /sesión venció/i
const IDLE = /sesión se cerró por inactividad/i

beforeEach(() => {
  loginMock.mockReset()
  pushMock.mockReset()
})

describe("LoginPage — ::explains_expired_reason", () => {
  it("explica el vencimiento cuando reason=expired", () => {
    withParams({ reason: "expired", next: "/caja" })

    render(<LoginPage />)

    expect(screen.getByText(EXPIRED)).toBeInTheDocument()
  })

  it("el aviso es un rol de alerta, igual que el de inactividad", () => {
    withParams({ reason: "expired" })

    render(<LoginPage />)

    const alerts = screen.getAllByRole("alert")
    expect(alerts.some((el) => EXPIRED.test(el.textContent ?? ""))).toBe(true)
  })

  it("no lo muestra sin reason", () => {
    withParams({})

    render(<LoginPage />)

    expect(screen.queryByText(EXPIRED)).not.toBeInTheDocument()
  })

  it("no lo muestra con otro reason", () => {
    withParams({ reason: "otro-motivo" })

    render(<LoginPage />)

    expect(screen.queryByText(EXPIRED)).not.toBeInTheDocument()
  })
})

describe("LoginPage — los dos motivos no se pisan", () => {
  it("reason=idle muestra el de inactividad y NO el de vencimiento", () => {
    withParams({ reason: "idle" })

    render(<LoginPage />)

    expect(screen.getByText(IDLE)).toBeInTheDocument()
    expect(screen.queryByText(EXPIRED)).not.toBeInTheDocument()
  })

  it("reason=expired muestra el de vencimiento y NO el de inactividad", () => {
    withParams({ reason: "expired" })

    render(<LoginPage />)

    expect(screen.getByText(EXPIRED)).toBeInTheDocument()
    expect(screen.queryByText(IDLE)).not.toBeInTheDocument()
  })
})

// ── Revisión adversarial de la Parte B (BLOCKER 2) ─────────────────────────
// `safeNext()` nació en D5 con dos consumidores declarados (middleware y
// callback), pero el **tercero** —y el único que corre en el caso real— quedó
// afuera: el formulario de login hacía `router.push(searchParams.get("next"))`
// crudo. Un usuario **anónimo** no dispara la rama `isAuthRoute` del middleware
// (la página de login es pública), así que nadie más valida ese destino.
//
// `router.push` con un origen ajeno hace navegación dura (`isExternalURL` de
// `next@16.1.6`: `url.origin !== window.location.origin` →
// `handleExternalUrl`), así que la víctima tipea sus credenciales en el dominio
// real y aterriza en el del atacante.
describe("LoginPage — el destino de retorno se valida también en el formulario", () => {
  async function submitLogin() {
    const user = userEvent.setup()
    await user.type(screen.getByLabelText(/correo|email/i), "duenio@test.local")
    await user.type(screen.getByLabelText(/contraseña/i), "secreto-123")
    await user.click(screen.getByRole("button", { name: /iniciar sesión/i }))
  }

  it.each([
    "https://evil.example/",
    "//evil.example",
    "@evil.example/",
    "/\\evil.example",
    "/\t/evil.example",
  ])("descarta %j y navega a la ruta principal", async (next) => {
    withParams({ next })
    loginMock.mockResolvedValue(undefined)

    render(<LoginPage />)
    await submitLogin()

    await waitFor(() => expect(pushMock).toHaveBeenCalled())
    expect(pushMock).toHaveBeenCalledWith("/dashboard")
  })

  it("conserva un destino interno", async () => {
    withParams({ next: "/caja?turno=2" })
    loginMock.mockResolvedValue(undefined)

    render(<LoginPage />)
    await submitLogin()

    await waitFor(() => expect(pushMock).toHaveBeenCalledWith("/caja?turno=2"))
  })

  it("sin destino va a la ruta principal", async () => {
    withParams({})
    loginMock.mockResolvedValue(undefined)

    render(<LoginPage />)
    await submitLogin()

    await waitFor(() => expect(pushMock).toHaveBeenCalledWith("/dashboard"))
  })

  it("un login fallido no navega a ningún lado", async () => {
    withParams({ next: "/caja" })
    loginMock.mockRejectedValue(new Error("credenciales inválidas"))

    render(<LoginPage />)
    await submitLogin()

    await waitFor(() => expect(loginMock).toHaveBeenCalled())
    expect(pushMock).not.toHaveBeenCalled()
  })
})

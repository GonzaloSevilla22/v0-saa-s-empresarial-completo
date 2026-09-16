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
import { render, screen } from "@testing-library/react"

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

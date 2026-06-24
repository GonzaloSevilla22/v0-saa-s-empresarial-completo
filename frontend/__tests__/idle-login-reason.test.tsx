/**
 * Tests for the login page idle-reason handling.
 *
 * Spec: "When the login page loads with reason=idle, the user is shown a
 * message indicating the session was closed due to inactivity."
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"

// ── Mocks ────────────────────────────────────────────────────────────────────

const loginMock = vi.fn()
const pushMock = vi.fn()
const toastInfoMock = vi.fn()

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ login: loginMock }),
}))

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: pushMock }),
  useSearchParams: vi.fn(),
}))

vi.mock("sonner", () => ({
  toast: {
    error: vi.fn(),
    success: vi.fn(),
    info: (...args: unknown[]) => toastInfoMock(...args),
  },
}))

vi.mock("next/link", () => ({
  default: ({ children, href }: { children: React.ReactNode; href: string }) => (
    <a href={href}>{children}</a>
  ),
}))

// Stub next/image if needed
vi.mock("@/components/auth/MagicLinkForm", () => ({
  MagicLinkForm: () => <div data-testid="magic-link-form" />,
}))

// ── Import and set up searchParams mock ──────────────────────────────────────

import { useSearchParams } from "next/navigation"
import LoginPage from "@/app/auth/login/page"

describe("LoginPage — idle reason", () => {
  beforeEach(() => {
    loginMock.mockReset()
    pushMock.mockReset()
    toastInfoMock.mockReset()
  })

  // ── 6.3 RED / 6.4 GREEN: shows idle message when reason=idle ─────────────

  it("shows a toast/message when reason=idle is present in the URL", () => {
    vi.mocked(useSearchParams).mockReturnValue({
      get: (key: string) => {
        if (key === "reason") return "idle"
        if (key === "next") return "/dashboard"
        return null
      },
    } as ReturnType<typeof useSearchParams>)

    render(<LoginPage />)

    // The idle message should be shown — either in-page or via toast.info
    // We check for the visible banner (our implementation uses a visible alert)
    expect(
      screen.getByText(/sesión se cerró por inactividad/i),
    ).toBeInTheDocument()
  })

  it("does NOT show the idle message when reason is absent", () => {
    vi.mocked(useSearchParams).mockReturnValue({
      get: (_: string) => null,
    } as ReturnType<typeof useSearchParams>)

    render(<LoginPage />)

    expect(
      screen.queryByText(/sesión se cerró por inactividad/i),
    ).not.toBeInTheDocument()
  })

  it("does NOT show the idle message when reason is something else", () => {
    vi.mocked(useSearchParams).mockReturnValue({
      get: (key: string) => (key === "reason" ? "expired" : null),
    } as ReturnType<typeof useSearchParams>)

    render(<LoginPage />)

    expect(
      screen.queryByText(/sesión se cerró por inactividad/i),
    ).not.toBeInTheDocument()
  })
})

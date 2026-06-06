/**
 * Component tests for PriceSuggestionModal (tasks 5.4, 5.5).
 *
 * Uses React Testing Library + vitest. To run:
 *   pnpm add -D vitest @vitejs/plugin-react jsdom @testing-library/react @testing-library/jest-dom
 *   pnpm vitest run __tests__/PriceSuggestionModal.test.tsx
 *
 * Note: This file requires a vitest.config.ts (or vitest.config.js) in the
 * project root that points at jsdom and configures the @/ path alias.
 * See __tests__/README.md (or vitest docs) for setup instructions.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import "@testing-library/jest-dom"

// ─── Mock dependencies that are not available in jsdom ───────────────────────

// Mock Supabase client
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    auth: {
      getSession: async () => ({
        data: { session: { access_token: "test-token" } },
      }),
    },
  }),
}))

// Mock Next.js Link
vi.mock("next/link", () => ({
  default: ({ href, children }: { href: string; children: React.ReactNode }) => (
    <a href={href}>{children}</a>
  ),
}))

// Mock global fetch — overridden per test
const mockFetch = vi.fn()
global.fetch = mockFetch

// ─── Helpers ─────────────────────────────────────────────────────────────────

function buildFetchResponse(body: unknown, status = 200) {
  return Promise.resolve({
    ok:     status >= 200 && status < 300,
    status,
    json:   () => Promise.resolve(body),
  } as Response)
}

// Lazy import to ensure mocks are set up first
async function renderModal(props?: Partial<{
  productId:   string
  productName: string
  isOpen:      boolean
  onClose:     () => void
}>) {
  const { PriceSuggestionModal } = await import("@/components/ai/PriceSuggestionModal")
  return render(
    <PriceSuggestionModal
      productId={props?.productId ?? "prod-123"}
      productName={props?.productName ?? "Producto Test"}
      isOpen={props?.isOpen ?? true}
      onClose={props?.onClose ?? vi.fn()}
    />
  )
}

// ─── task 5.4: spinner in loading state ──────────────────────────────────────

describe("PriceSuggestionModal — loading state (task 5.4)", () => {
  beforeEach(() => {
    // Never resolves — keeps modal in loading state
    mockFetch.mockReturnValue(new Promise(() => {}))
  })

  it("shows a loading spinner while the Edge Function is in-flight", async () => {
    await renderModal()
    // The spinner role is "status" with aria-label
    const status = screen.getByRole("status")
    expect(status).toBeInTheDocument()
  })

  it("shows loading copy text", async () => {
    await renderModal()
    expect(screen.getByText(/analizando historial/i)).toBeInTheDocument()
  })
})

// ─── task 5.5: insufficient_data message ─────────────────────────────────────

describe("PriceSuggestionModal — insufficient_data fallback (task 5.5)", () => {
  beforeEach(() => {
    mockFetch.mockReturnValue(
      buildFetchResponse({ ok: true, fallback: true, reason: "insufficient_data" })
    )
  })

  it("shows the 'no sufficient history' message for insufficient_data", async () => {
    await renderModal()
    await waitFor(() => {
      expect(
        screen.getByText(/no hay suficiente historial de ventas para sugerir un precio/i)
      ).toBeInTheDocument()
    })
  })

  it("shows the '3 ventas en los últimos 90 días' instruction", async () => {
    await renderModal()
    await waitFor(() => {
      expect(screen.getByText(/al menos 3 ventas en los últimos 90 días/i)).toBeInTheDocument()
    })
  })
})

// ─── timeout fallback ─────────────────────────────────────────────────────────

describe("PriceSuggestionModal — timeout fallback", () => {
  beforeEach(() => {
    mockFetch.mockReturnValue(
      buildFetchResponse({ ok: true, fallback: true, reason: "timeout" })
    )
  })

  it("shows timeout message for reason:'timeout'", async () => {
    await renderModal()
    await waitFor(() => {
      expect(screen.getByText(/el análisis está tardando más de lo esperado/i)).toBeInTheDocument()
    })
  })
})

// ─── quota_exceeded error ─────────────────────────────────────────────────────

describe("PriceSuggestionModal — quota_exceeded error", () => {
  beforeEach(() => {
    mockFetch.mockReturnValue(
      buildFetchResponse(
        { ok: false, error: "quota_exceeded" },
        429
      )
    )
  })

  it("shows quota exceeded message and a link to /planes", async () => {
    await renderModal()
    await waitFor(() => {
      expect(screen.getByText("Límite mensual alcanzado")).toBeInTheDocument()
    })
    const link = screen.getByRole("link", { name: /ver planes/i })
    expect(link).toHaveAttribute("href", "/planes")
  })
})

// ─── success state ────────────────────────────────────────────────────────────

describe("PriceSuggestionModal — success state", () => {
  beforeEach(() => {
    mockFetch.mockReturnValue(
      buildFetchResponse({
        ok:              true,
        suggested_price: 1500,
        margin_pct:      35.5,
        argument:        "Subir el precio a $1.500 aumentaría el margen a 35.5%.",
      })
    )
  })

  it("shows the suggested price formatted in ARS", async () => {
    await renderModal()
    await waitFor(() => {
      // The price label container has "Precio sugerido" heading
      expect(screen.getByText(/precio sugerido/i)).toBeInTheDocument()
      // The formatted price should be in a bold element — find all matches and verify at least one
      const matches = screen.getAllByText(/1[.,. ]500/)
      expect(matches.length).toBeGreaterThan(0)
    })
  })

  it("shows the projected margin percentage", async () => {
    await renderModal()
    await waitFor(() => {
      // Use getAllByText because the argument string may also contain the same pct
      const matches = screen.getAllByText(/35[.,]5/)
      expect(matches.length).toBeGreaterThan(0)
    })
  })

  it("shows the AI argument text", async () => {
    await renderModal()
    await waitFor(() => {
      expect(screen.getByText(/subir el precio/i)).toBeInTheDocument()
    })
  })

  it("shows the disclaimer text", async () => {
    await renderModal()
    await waitFor(() => {
      expect(screen.getByText(/la decisión final es tuya/i)).toBeInTheDocument()
    })
  })
})

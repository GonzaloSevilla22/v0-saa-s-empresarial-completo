/**
 * clientes-frecuentes-historial — TDD tests para ClientPurchaseHistory
 * (task 8.3 RED / 8.4 GREEN / 8.5 TRIANGULATE).
 */

import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import { ClientPurchaseHistory } from "@/components/clientes/ClientPurchaseHistory"
import type { ClientPurchase } from "@/hooks/data/use-client-activity"
import type { PaginationMeta } from "@/lib/pagination-utils"

const PURCHASES: ClientPurchase[] = [
  { operationId: "op-1", operationDate: "2026-08-01", itemCount: 3, total: 3000 },
  { operationId: "op-2", operationDate: "2026-07-15", itemCount: 1, total: 500 },
]

const META: PaginationMeta = { page: 0, pageSize: 25, totalCount: 2, pageCount: 1, from: 1, to: 2 }

describe("ClientPurchaseHistory", () => {
  it("renders one row per operation with date, item count and total", () => {
    render(
      <ClientPurchaseHistory
        purchases={PURCHASES}
        meta={META}
        isLoading={false}
        error={null}
        onPageChange={vi.fn()}
        onSizeChange={vi.fn()}
      />
    )
    expect(screen.getByText(/3\.?000/)).toBeInTheDocument()
    expect(screen.getByText(/500/)).toBeInTheDocument()
  })

  // ── 8.5 TRIANGULATE: estado vacío ─────────────────────────────────────────
  it("shows an empty state when the client has no purchases", () => {
    render(
      <ClientPurchaseHistory
        purchases={[]}
        meta={{ ...META, totalCount: 0, pageCount: 1 }}
        isLoading={false}
        error={null}
        onPageChange={vi.fn()}
        onSizeChange={vi.fn()}
      />
    )
    expect(screen.getByText(/todavía no compró/i)).toBeInTheDocument()
  })

  // ── 8.5 TRIANGULATE: loading ──────────────────────────────────────────────
  it("shows a loading state", () => {
    render(
      <ClientPurchaseHistory
        purchases={[]}
        meta={META}
        isLoading
        error={null}
        onPageChange={vi.fn()}
        onSizeChange={vi.fn()}
      />
    )
    expect(screen.getByTestId("client-purchase-history-loading")).toBeInTheDocument()
  })

  // ── 8.5 TRIANGULATE: error ────────────────────────────────────────────────
  it("shows an error message", () => {
    render(
      <ClientPurchaseHistory
        purchases={[]}
        meta={META}
        isLoading={false}
        error="Error al cargar el historial"
        onPageChange={vi.fn()}
        onSizeChange={vi.fn()}
      />
    )
    expect(screen.getByText(/error al cargar el historial/i)).toBeInTheDocument()
  })
})

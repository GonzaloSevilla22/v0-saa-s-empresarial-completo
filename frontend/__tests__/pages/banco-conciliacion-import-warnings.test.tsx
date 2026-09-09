/**
 * ConciliacionTab (/banco) — avisos y descartes del importador de extracto
 * (candidatos-importadores, 2026-09-09): `parseBankStatementText` ahora
 * devuelve `warnings` por línea (importe/saldo ambiguo, punto de miles) y
 * `discarded` (filas con importe ilegible que se omiten sin abortar el
 * archivo). La UI tiene que mostrar ambos, mismo patrón (tokens semánticos,
 * conteo + detalle) que ProductImportDialog/ExpenseImportDialog.
 *
 * `ConciliacionTab` se prueba importado directo (exportado para test,
 * mismo patrón que `parseAndValidate` en expense-import-dialog.tsx) para no
 * depender del Select de cuenta bancaria de `BancoPage` — Radix Select no
 * abre bien en jsdom (gotcha documentado en PaymentMethodSelect.test.tsx).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import React from "react"

// El módulo de la página importa BankAccountFormDialog → useBankAccounts →
// lib/api/python-client.ts, que explota si NEXT_PUBLIC_BACKEND_URL no está
// seteada — sin usarlo directamente, ConciliacionTab arrastra el import
// completo del módulo (mismo mock que BancoPage.test.tsx).
vi.mock("@/hooks/data/use-bank-accounts", () => ({
  useBankAccounts: () => ({
    data: [],
    isLoading: false,
    createBankAccount: vi.fn(),
    createBankAccountMutation: { isPending: false },
  }),
}))

vi.mock("@/hooks/data/use-bank-reconciliation", () => ({
  useReconciliationSessions: () => ({ data: [] }),
  useStatementImports: () => ({ data: [] }),
  useImportStatement: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useOpenSession: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useRegisterManualMovement: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))

// Mismo motivo que useBankAccounts arriba: MovimientosTab (la otra tab del
// mismo módulo) importa fetchBankMovementsPage a nivel de módulo.
vi.mock("@/hooks/data/use-bank-movements", () => ({
  fetchBankMovementsPage: vi.fn().mockResolvedValue({ items: [], total: 0, page: 0, pages: 0 }),
}))

vi.mock("@/components/bank-reconciliation/ReconciliationBoard", () => ({
  ReconciliationBoard: () => <div data-testid="reconciliation-board" />,
}))

vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn(), info: vi.fn() } }))

const mockParseBankStatementFile = vi.fn()
vi.mock("@/lib/bank-statement-parser", async () => {
  const actual =
    await vi.importActual<typeof import("@/lib/bank-statement-parser")>("@/lib/bank-statement-parser")
  return {
    ...actual,
    parseBankStatementFile: (...args: unknown[]) => mockParseBankStatementFile(...args),
    hashFileSHA256: vi.fn().mockResolvedValue("hash-abc"),
  }
})

async function renderConciliacionTab() {
  const { ConciliacionTab } = await import("@/app/(dashboard)/banco/page")
  return render(<ConciliacionTab bankAccountId="ba-1" />)
}

function selectFileInput(): HTMLInputElement {
  return document.querySelector('input[type="file"]') as HTMLInputElement
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe("ConciliacionTab — avisos de ambigüedad", () => {
  it("muestra el conteo y el detalle de advertencias cuando el parser devuelve líneas ambiguas", async () => {
    mockParseBankStatementFile.mockResolvedValue({
      ok: true,
      lines: [
        {
          line_no: 1,
          value_date: "2026-07-15",
          description: "Movimiento ambiguo",
          amount: "1.500",
          balance: null,
          warnings: [
            'Importe ambiguo: "1.500" — se interpretó como $ 1,5. Usá coma para decimales y ningún separador para miles.',
          ],
          source_row: 2,
        },
      ],
      discarded: [],
    })

    const user = userEvent.setup()
    await renderConciliacionTab()

    const file = new File(["Fecha;Importe\n15/07/2026;1.500"], "extracto.csv", { type: "text/csv" })
    await user.upload(selectFileInput(), file)

    await waitFor(() => expect(screen.getByText(/1 advertencia/)).toBeInTheDocument())
    expect(screen.getByText(/Importe ambiguo: "1\.500"/)).toBeInTheDocument()
    expect(screen.queryByText(/descartada/)).not.toBeInTheDocument()
  })

  it("F5: el aviso se numera con la fila física del archivo (source_row), la misma convención que usan los descartes", async () => {
    mockParseBankStatementFile.mockResolvedValue({
      ok: true,
      lines: [
        {
          line_no: 1, // única línea válida → line_no siempre 1, distinto de la fila física real
          value_date: "2026-07-16",
          description: "Movimiento ambiguo",
          amount: "1.500",
          balance: null,
          warnings: [
            'Importe ambiguo: "1.500" — se interpretó como $ 1,5. Usá coma para decimales y ningún separador para miles.',
          ],
          source_row: 3, // fila física real: la fila 2 del archivo se descartó antes
        },
      ],
      discarded: [
        { row: 2, reason: 'Importe ilegible: "abc" — no se puede registrar un movimiento sin importe.' },
      ],
    })

    const user = userEvent.setup()
    await renderConciliacionTab()

    const file = new File(
      ["Fecha;Importe\n15/07/2026;abc\n16/07/2026;1.500"],
      "extracto.csv",
      { type: "text/csv" },
    )
    await user.upload(selectFileInput(), file)

    await waitFor(() => expect(screen.getByText(/1 advertencia/)).toBeInTheDocument())
    // El aviso tiene que citar la fila física 3 (source_row), NO line_no (1)
    // — antes decía "Línea 1", una numeración distinta a la fila física real
    // que ya usaba el descarte de al lado ("Fila 2").
    expect(screen.getByText(/Fila 3: Importe ambiguo/)).toBeInTheDocument()
    expect(screen.queryByText(/Línea 1/)).not.toBeInTheDocument()
  })
})

describe("ConciliacionTab — filas descartadas", () => {
  it("muestra el conteo y el detalle de filas descartadas cuando el parser rechaza un importe", async () => {
    mockParseBankStatementFile.mockResolvedValue({
      ok: true,
      lines: [
        {
          line_no: 1,
          value_date: "2026-07-16",
          description: "Movimiento ok",
          amount: "100.00",
          balance: null,
          warnings: [],
        },
      ],
      discarded: [
        { row: 2, reason: 'Importe ilegible: "abc" — no se puede registrar un movimiento sin importe.' },
      ],
    })

    const user = userEvent.setup()
    await renderConciliacionTab()

    const file = new File(
      ["Fecha;Importe\n15/07/2026;abc\n16/07/2026;100,00"],
      "extracto.csv",
      { type: "text/csv" },
    )
    await user.upload(selectFileInput(), file)

    await waitFor(() => expect(screen.getByText(/1 descartada/)).toBeInTheDocument())
    expect(screen.getByText(/Fila 2: Importe ilegible/)).toBeInTheDocument()
    expect(screen.queryByText(/advertencia/)).not.toBeInTheDocument()
  })

  it("sin advertencias ni descartes no muestra ningún badge ni panel de detalle", async () => {
    mockParseBankStatementFile.mockResolvedValue({
      ok: true,
      lines: [
        {
          line_no: 1,
          value_date: "2026-07-16",
          description: "Movimiento ok",
          amount: "100.00",
          balance: null,
          warnings: [],
        },
      ],
      discarded: [],
    })

    const user = userEvent.setup()
    await renderConciliacionTab()

    const file = new File(["Fecha;Importe\n16/07/2026;100,00"], "extracto.csv", { type: "text/csv" })
    await user.upload(selectFileInput(), file)

    await waitFor(() => expect(screen.getByText(/extracto\.csv/)).toBeInTheDocument())
    expect(screen.queryByText(/advertencia/)).not.toBeInTheDocument()
    expect(screen.queryByText(/descartada/)).not.toBeInTheDocument()
  })
})

// F3 — el límite de alto (max-h-40) tiene que vivir en el VIEWPORT interno de
// Radix ScrollArea, no en el root (overflow-hidden): un max-h en el root
// RECORTA el contenido sin habilitar scroll (qa-integral-modulos G5/H5).
describe("ConciliacionTab — F3: el panel de avisos/descartes scrollea en vez de recortar", () => {
  it("max-h-40 vive en el viewport de ScrollArea, el root NO lo tiene", async () => {
    mockParseBankStatementFile.mockResolvedValue({
      ok: true,
      lines: [
        {
          line_no: 1,
          value_date: "2026-07-16",
          description: "Movimiento ok",
          amount: "100.00",
          balance: null,
          warnings: [],
          source_row: 2,
        },
      ],
      discarded: [
        { row: 3, reason: 'Importe ilegible: "abc" — no se puede registrar un movimiento sin importe.' },
      ],
    })

    const user = userEvent.setup()
    await renderConciliacionTab()

    const file = new File(
      ["Fecha;Importe\n16/07/2026;100,00\n17/07/2026;abc"],
      "extracto.csv",
      { type: "text/csv" },
    )
    await user.upload(selectFileInput(), file)

    await waitFor(() => expect(screen.getByText(/1 descartada/)).toBeInTheDocument())

    const viewport = document.querySelector("[data-radix-scroll-area-viewport]")
    expect(viewport).toBeTruthy()
    expect(viewport?.className).toMatch(/max-h-40/)
    // El root (padre del viewport) es overflow-hidden — un max-h ahí recorta
    // sin scroll, por eso NO debe tenerlo.
    expect(viewport?.parentElement?.className).not.toMatch(/max-h-/)
  })
})

// F11 (nit) — un valor crudo sin acotar puede inflar el mensaje sin límite;
// el detalle necesita break-all (para no desbordar con basura sin espacios);
// el nombre de archivo necesita truncate (para no romper el layout con un
// nombre largo).
describe("ConciliacionTab — F11: valores acotados y wrapping en el panel de detalle", () => {
  it("el nombre de archivo largo trunca (truncate + max-w) sin romper el layout", async () => {
    mockParseBankStatementFile.mockResolvedValue({
      ok: true,
      lines: [
        {
          line_no: 1,
          value_date: "2026-07-16",
          description: "Movimiento ok",
          amount: "100.00",
          balance: null,
          warnings: [],
          source_row: 2,
        },
      ],
      discarded: [],
    })

    const user = userEvent.setup()
    await renderConciliacionTab()

    const longName = "extracto-banco-galicia-cuenta-corriente-julio-2026-detallado-completo.csv"
    const file = new File(["Fecha;Importe\n16/07/2026;100,00"], longName, { type: "text/csv" })
    await user.upload(selectFileInput(), file)

    await waitFor(() => expect(screen.getByText(new RegExp(longName.slice(0, 20)))).toBeInTheDocument())
    const fileNameEl = screen.getByText(new RegExp(longName.slice(0, 20)))
    // Busca el ancestro con las clases de truncado (el <b> puede no llevarlas
    // directamente si se envuelve en un span contenedor).
    const truncated = fileNameEl.closest(".truncate") ?? fileNameEl
    expect(truncated.className).toMatch(/truncate/)
    expect(truncated.className).toMatch(/max-w-\[200px\]/)
  })

  it("el detalle de avisos/descartes usa break-all", async () => {
    mockParseBankStatementFile.mockResolvedValue({
      ok: true,
      lines: [
        {
          line_no: 1,
          value_date: "2026-07-16",
          description: "Movimiento ok",
          amount: "100.00",
          balance: null,
          warnings: [],
          source_row: 2,
        },
      ],
      discarded: [
        { row: 3, reason: 'Importe ilegible: "abc" — no se puede registrar un movimiento sin importe.' },
      ],
    })

    const user = userEvent.setup()
    await renderConciliacionTab()

    const file = new File(
      ["Fecha;Importe\n16/07/2026;100,00\n17/07/2026;abc"],
      "extracto.csv",
      { type: "text/csv" },
    )
    await user.upload(selectFileInput(), file)

    await waitFor(() => expect(screen.getByText(/Fila 3: Importe ilegible/)).toBeInTheDocument())
    const detailSpan = screen.getByText(/Fila 3: Importe ilegible/)
    expect(detailSpan.className).toMatch(/break-all/)
  })
})

// F12 (nit) — el panel de avisos/descartes es contenido que aparece de forma
// asíncrona tras elegir el archivo; sin role="status"/aria-live, un lector de
// pantalla no se entera de que apareció.
describe("ConciliacionTab — F12: el panel de avisos/descartes anuncia su aparición (a11y)", () => {
  it('el contenedor del panel tiene role="status" y aria-live="polite"', async () => {
    mockParseBankStatementFile.mockResolvedValue({
      ok: true,
      lines: [
        {
          line_no: 1,
          value_date: "2026-07-16",
          description: "Movimiento ok",
          amount: "100.00",
          balance: null,
          warnings: [],
          source_row: 2,
        },
      ],
      discarded: [
        { row: 3, reason: 'Importe ilegible: "abc" — no se puede registrar un movimiento sin importe.' },
      ],
    })

    const user = userEvent.setup()
    await renderConciliacionTab()

    const file = new File(
      ["Fecha;Importe\n16/07/2026;100,00\n17/07/2026;abc"],
      "extracto.csv",
      { type: "text/csv" },
    )
    await user.upload(selectFileInput(), file)

    await waitFor(() => expect(screen.getByText(/1 descartada/)).toBeInTheDocument())
    const panel = screen.getByRole("status")
    expect(panel).toBeTruthy()
    expect(panel.getAttribute("aria-live")).toBe("polite")
  })
})

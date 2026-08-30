/**
 * Importador de gastos — invalidaciones (hallazgo de la revisión adversarial
 * del apply, 2026-08-29).
 *
 * `handleApply` recorre las filas del CSV en serie y llama al alta UNA VEZ POR
 * FILA. Antes de este change cada éxito invalidaba una sola raíz (`expenses`);
 * D18 subió el set a SEIS (expenses, cashSessions, cashMovements, bankAccounts,
 * bankReconciliation, paymentMethods) y además montó queries activas sobre dos
 * de ellas en /gastos. Medido sobre el diálogo real: un CSV de 5 filas pasaba
 * de 5 GETs (main) a 10-15 (rama), todos descartados salvo el último.
 *
 * Y en el camino de importación las seis invalidaciones son **inútiles por
 * definición**: por D13 las filas importadas viajan sin forma de pago, sin
 * sesión de caja y sin cuenta bancaria, así que un alta por importación no
 * puede tocar caja, banco ni el catálogo. La invalidación va UNA vez al
 * terminar el lote, no por fila.
 *
 * El assert es de INVARIANZA respecto de la cantidad de filas: contar "6" sobre
 * un CSV de 1 fila no distinguiría el antes del después.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor, fireEvent } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

// `vi.hoisted` porque la factory de `vi.mock` se iza por encima de las
// declaraciones del módulo (gotcha ya documentado en el repo).
const { get, post } = vi.hoisted(() => ({
  get:  vi.fn(),
  post: vi.fn(),
}))

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get, post, put: vi.fn(), delete: vi.fn() },
}))
vi.mock("sonner", () => ({
  toast: { success: vi.fn(), error: vi.fn(), warning: vi.fn() },
}))

import { ExpenseImportDialog } from "@/components/gastos/expense-import-dialog"

function csvWith(rowCount: number): string {
  const header = "Descripción;Categoría;Monto;Fecha"
  const rows = Array.from({ length: rowCount }, (_, i) =>
    `Gasto ${i + 1};Servicios;${(i + 1) * 1000};2026-08-0${(i % 9) + 1}`,
  )
  return [header, ...rows].join("\n")
}

async function importCsv(csv: string, rowCount: number) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const invalidateSpy = vi.spyOn(queryClient, "invalidateQueries")

  render(
    React.createElement(
      QueryClientProvider,
      { client: queryClient },
      React.createElement(ExpenseImportDialog, { open: true, onOpenChange: vi.fn() }),
    ),
  )

  const input = document.getElementById("csv-expense-upload") as HTMLInputElement
  fireEvent.change(input, { target: { files: [new File([csv], "gastos.csv", { type: "text/csv" })] } })

  const label = new RegExp(`importar ${rowCount} gastos?`, "i")
  await waitFor(() => expect(screen.getByRole("button", { name: label })).toBeInTheDocument())
  fireEvent.click(screen.getByRole("button", { name: label }))
  await waitFor(() => expect(post).toHaveBeenCalledTimes(rowCount))

  return invalidateSpy
}

beforeEach(() => {
  vi.clearAllMocks()
  get.mockResolvedValue({ items: [], total: 0, page: 0, pages: 0 })
  post.mockResolvedValue({ id: "exp-nuevo" })
})

describe("ExpenseImportDialog — la importación invalida una sola vez, no por fila", () => {
  it("un lote de 3 filas invalida el mismo número de veces que uno de 6", async () => {
    const spy3 = await importCsv(csvWith(3), 3)
    const calls3 = spy3.mock.calls.length

    vi.clearAllMocks()
    get.mockResolvedValue({ items: [], total: 0, page: 0, pages: 0 })
    post.mockResolvedValue({ id: "exp-nuevo" })

    const spy6 = await importCsv(csvWith(6), 6)
    const calls6 = spy6.mock.calls.length

    expect(calls3).toBe(calls6)
    // Control positivo: el lote SÍ invalida (un cero haría pasar la igualdad
    // de arriba sin que nadie refresque nada).
    expect(calls3).toBeGreaterThan(0)
  })

  it("no dispara un refetch del listado por cada fila", async () => {
    await importCsv(csvWith(6), 6)
    const listGets = get.mock.calls.filter(([url]) => String(url).startsWith("/expenses"))
    // Con la invalidación por fila el listado se refetcheaba una vez por alta.
    expect(listGets.length).toBeLessThanOrEqual(2)
  })

  it("una importación en la que TODAS las altas fallan no invalida nada", async () => {
    // Nada se escribió: invalidar seis raíces sólo produce refetches inútiles.
    post.mockRejectedValue(new Error("boom"))

    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const invalidateSpy = vi.spyOn(queryClient, "invalidateQueries")

    render(
      React.createElement(
        QueryClientProvider,
        { client: queryClient },
        React.createElement(ExpenseImportDialog, { open: true, onOpenChange: vi.fn() }),
      ),
    )

    const input = document.getElementById("csv-expense-upload") as HTMLInputElement
    fireEvent.change(input, {
      target: { files: [new File([csvWith(2)], "gastos.csv", { type: "text/csv" })] },
    })

    await waitFor(() => expect(screen.getByRole("button", { name: /importar 2 gastos/i })).toBeInTheDocument())
    fireEvent.click(screen.getByRole("button", { name: /importar 2 gastos/i }))

    await waitFor(() => expect(post).toHaveBeenCalledTimes(2))
    expect(invalidateSpy).not.toHaveBeenCalled()
  })
})

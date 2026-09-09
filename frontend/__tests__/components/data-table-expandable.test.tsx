/**
 * DataTable — expandable-row support (sucursal-guard-vaciado-auditoria OQ-5).
 *
 * `renderExpanded` is an OPT-IN prop: without it, DataTable must render
 * exactly as before (no extra column, no toggle button, no markup change) —
 * every other consumer of DataTable must stay byte-for-byte unaffected.
 * With it, each row gets a toggle that lazily mounts the expanded content.
 */
import { describe, it, expect } from "vitest"
import { render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { DataTable, type Column } from "@/components/data-table/data-table"

interface Row {
  id: string
  name: string
}

const DATA: Row[] = [
  { id: "p1", name: "Producto Uno" },
  { id: "p2", name: "Producto Dos" },
]

const COLUMNS: Column<Row>[] = [
  { key: "name", header: "Producto", cell: (row) => row.name },
]

describe("DataTable — sin renderExpanded (regresión de consumidores existentes)", () => {
  it("no renderiza ningún botón de despliegue ni columna extra", () => {
    render(<DataTable data={DATA} columns={COLUMNS} getId={(row) => row.id} />)

    expect(screen.queryByRole("button", { name: /desglose/i })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /ver .* de/i })).not.toBeInTheDocument()
    // Only the header + 2 data rows, no expansion row ever added.
    expect(screen.getAllByRole("row")).toHaveLength(3)
  })
})

describe("DataTable — con renderExpanded", () => {
  function renderTable() {
    return render(
      <DataTable
        data={DATA}
        columns={COLUMNS}
        getId={(row) => row.id}
        expandLabel={(row) => row.name}
        renderExpanded={(row) => <div data-testid={`expanded-${row.id}`}>Contenido de {row.name}</div>}
      />
    )
  }

  it("arranca colapsado: el contenido expandido no está en el DOM y aria-expanded es false", () => {
    renderTable()
    const toggle = screen.getByRole("button", { name: "Ver desglose por sucursal de Producto Uno" })
    expect(toggle).toHaveAttribute("aria-expanded", "false")
    expect(screen.queryByTestId("expanded-p1")).not.toBeInTheDocument()
  })

  it("al hacer click despliega el contenido de ESA fila y cambia aria-expanded/aria-label", async () => {
    const user = userEvent.setup()
    renderTable()

    await user.click(screen.getByRole("button", { name: "Ver desglose por sucursal de Producto Uno" }))

    const toggle = screen.getByRole("button", { name: "Ocultar desglose por sucursal de Producto Uno" })
    expect(toggle).toHaveAttribute("aria-expanded", "true")
    expect(screen.getByTestId("expanded-p1")).toBeInTheDocument()
    // The other row stays collapsed.
    expect(screen.queryByTestId("expanded-p2")).not.toBeInTheDocument()
  })

  it("al hacer click de nuevo oculta el contenido", async () => {
    const user = userEvent.setup()
    renderTable()

    await user.click(screen.getByRole("button", { name: "Ver desglose por sucursal de Producto Uno" }))
    await user.click(screen.getByRole("button", { name: "Ocultar desglose por sucursal de Producto Uno" }))

    expect(screen.queryByTestId("expanded-p1")).not.toBeInTheDocument()
    expect(
      screen.getByRole("button", { name: "Ver desglose por sucursal de Producto Uno" })
    ).toHaveAttribute("aria-expanded", "false")
  })

  it("la fila expandida usa colSpan = total de columnas (1 dato + 1 toggle)", async () => {
    const user = userEvent.setup()
    renderTable()
    await user.click(screen.getByRole("button", { name: "Ver desglose por sucursal de Producto Uno" }))

    const cell = screen.getByTestId("expanded-p1").closest("td")
    expect(cell).toHaveAttribute("colspan", "2")
  })

  it("sin expandLabel, usa getId(row) como nombre en el aria-label", () => {
    render(
      <DataTable
        data={DATA}
        columns={COLUMNS}
        getId={(row) => row.id}
        renderExpanded={(row) => <div data-testid={`expanded-${row.id}`}>x</div>}
      />
    )
    expect(screen.getByRole("button", { name: "Ver desglose por sucursal de p1" })).toBeInTheDocument()
  })
})

describe("DataTable — modo mobileCard con renderExpanded", () => {
  it("ofrece un botón «Desglose por sucursal» bajo cada card que alterna el mismo contenido", async () => {
    // Desktop table and mobile card list coexist in the DOM (CSS-hidden by
    // breakpoint, same as the existing onEdit/onDelete row) — scope to the
    // mobile-only container to assert the mobile toggle independently.
    const user = userEvent.setup()
    const { container } = render(
      <DataTable
        data={DATA}
        columns={COLUMNS}
        getId={(row) => row.id}
        expandLabel={(row) => row.name}
        mobileCard={(row) => <span>{row.name}</span>}
        renderExpanded={(row) => <div data-testid={`expanded-${row.id}`}>Contenido de {row.name}</div>}
      />
    )

    const mobileSection = container.querySelector(".sm\\:hidden")
    expect(mobileSection).toBeTruthy()
    const toggles = within(mobileSection as HTMLElement).getAllByText("Desglose por sucursal")
    expect(toggles.length).toBe(DATA.length)

    await user.click(toggles[0])
    expect(within(mobileSection as HTMLElement).getByTestId("expanded-p1")).toBeInTheDocument()
  })
})

describe("DataTable — expandContentLabel personalizado (F7, revisor adversarial tanda6)", () => {
  // El componente compartido quedó con copy de dominio de stock horneado
  // adentro ("desglose por sucursal" literal en los 2 aria-label + el botón
  // mobile) pese a exponer renderExpanded/expandLabel como API genérica. Un
  // segundo consumidor (movimientos de cuenta, líneas de una operación)
  // heredaría una etiqueta que miente — y para un lector de pantalla la
  // mentira es el único texto disponible.
  it("sin expandContentLabel, mantiene el default 'desglose por sucursal' (comportamiento preexistente intacto)", () => {
    render(
      <DataTable
        data={DATA}
        columns={COLUMNS}
        getId={(row) => row.id}
        expandLabel={(row) => row.name}
        renderExpanded={(row) => <div data-testid={`expanded-${row.id}`}>x</div>}
      />
    )
    expect(screen.getByRole("button", { name: "Ver desglose por sucursal de Producto Uno" })).toBeInTheDocument()
  })

  it("con expandContentLabel custom, lo usa en el aria-label desktop en vez del texto de stock hardcodeado", () => {
    render(
      <DataTable
        data={DATA}
        columns={COLUMNS}
        getId={(row) => row.id}
        expandLabel={(row) => row.name}
        expandContentLabel="movimientos de cuenta"
        renderExpanded={(row) => <div data-testid={`expanded-${row.id}`}>x</div>}
      />
    )
    expect(screen.getByRole("button", { name: "Ver movimientos de cuenta de Producto Uno" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /desglose por sucursal/i })).not.toBeInTheDocument()
  })

  it("con expandContentLabel custom, el botón mobile muestra ese texto capitalizado en vez de 'Desglose por sucursal'", () => {
    const { container } = render(
      <DataTable
        data={DATA}
        columns={COLUMNS}
        getId={(row) => row.id}
        expandLabel={(row) => row.name}
        expandContentLabel="movimientos de cuenta"
        mobileCard={(row) => <span>{row.name}</span>}
        renderExpanded={(row) => <div data-testid={`expanded-${row.id}`}>x</div>}
      />
    )
    const mobileSection = container.querySelector(".sm\\:hidden")
    const toggles = within(mobileSection as HTMLElement).getAllByText("Movimientos de cuenta")
    expect(toggles.length).toBe(DATA.length)
    expect(within(mobileSection as HTMLElement).queryByText("Desglose por sucursal")).not.toBeInTheDocument()
  })
})

describe("DataTable — TableHead del toggle tiene nombre accesible (F8, revisor adversarial tanda6)", () => {
  // Antes de este fix, <TableHead className="w-10" /> quedaba sin ningún
  // nombre accesible — un lector de pantalla anuncia una columna sin
  // nombre en cada fila al recorrer la tabla.
  it("la columna del toggle expone un texto sr-only en el encabezado", () => {
    render(
      <DataTable
        data={DATA}
        columns={COLUMNS}
        getId={(row) => row.id}
        renderExpanded={(row) => <div data-testid={`expanded-${row.id}`}>x</div>}
      />
    )
    const headerRow = screen.getAllByRole("row")[0]
    const srLabel = within(headerRow).getByText("Desglose")
    expect(srLabel).toHaveClass("sr-only")
    expect(srLabel.closest("th")).toBeInTheDocument()
  })
})

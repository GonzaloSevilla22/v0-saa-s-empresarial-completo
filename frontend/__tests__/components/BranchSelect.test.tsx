/**
 * remitos-venta (D11, tarea 4.7) — `BranchSelect` suma dos props ADITIVAS:
 *
 *   - `required`:      sin la opción "Sin sucursal" (el remito sale de una
 *                      sucursal concreta; `null` no es un valor posible) y sin
 *                      las sucursales CERRADAS (el servidor las rechazaría con
 *                      `branch_closed`).
 *   - `alwaysVisible`: se muestra aunque el plan no tenga módulo de sucursales
 *                      (3 de los 4 planes): el remito necesita la sucursal en
 *                      todos.
 *
 * Los usos actuales (ninguna de las dos) no cambian: nada con plan sin módulo,
 * "Sin sucursal (general)" siempre ofrecida.
 *
 * Radix Select no abre en jsdom (Portal + pointer capture): se sustituye
 * `@/components/ui/select` por un doble plano que lista las opciones, y los
 * hooks de plan y sucursales se mockean.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import type { ReactNode } from "react"
import { BranchSelect } from "@/components/branches/BranchSelect"
import type { Branch } from "@/lib/types"

vi.mock("@/components/ui/select", () => ({
  Select: ({
    value,
    onValueChange,
    children,
  }: {
    value?: string
    onValueChange?: (v: string) => void
    children: ReactNode
  }) => (
    <div data-testid="select" data-value={value} data-on-change={onValueChange ? "yes" : "no"}>
      <SelectChangeContext.Provider value={onValueChange}>{children}</SelectChangeContext.Provider>
    </div>
  ),
  SelectTrigger: ({ children, className }: { children: ReactNode; className?: string }) => (
    <button type="button" role="combobox" className={className}>
      {children}
    </button>
  ),
  SelectValue: ({ placeholder }: { placeholder?: string }) => <span data-testid="placeholder">{placeholder}</span>,
  SelectContent: ({ children }: { children: ReactNode }) => <div role="listbox">{children}</div>,
  SelectItem: ({ value, children }: { value: string; children: ReactNode }) => <SelectItemDouble value={value}>{children}</SelectItemDouble>,
}))

import { createContext, useContext } from "react"
const SelectChangeContext = createContext<((v: string) => void) | undefined>(undefined)
function SelectItemDouble({ value, children }: { value: string; children: ReactNode }) {
  const onChange = useContext(SelectChangeContext)
  return (
    <button type="button" role="option" onClick={() => onChange?.(value)}>
      {children}
    </button>
  )
}

const usePlanLimitsMock = vi.fn()
vi.mock("@/hooks/auth/use-plan-limits", () => ({ usePlanLimits: () => usePlanLimitsMock() }))

const useBranchesMock = vi.fn()
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => useBranchesMock() }))

function branch(overrides: Partial<Branch> & { id: string; name: string }): Branch {
  return {
    accountId: "acc-1",
    address: null,
    isActive: true,
    createdAt: "2026-01-01T00:00:00Z",
    status: "active",
    openedAt: null,
    closedAt: null,
    createdBy: null,
    deactivatedAt: null,
    deactivatedBy: null,
    ...overrides,
  }
}

const CENTRO = branch({ id: "b-centro", name: "Centro" })
const SHOWROOM = branch({ id: "b-show", name: "Showroom", createdAt: "2026-03-01T00:00:00Z" })
const CERRADA = branch({ id: "b-cerrada", name: "Depósito viejo", status: "closed" })

beforeEach(() => {
  vi.clearAllMocks()
  usePlanLimitsMock.mockReturnValue({ limits: { hasBranchesModule: true } })
  useBranchesMock.mockReturnValue({ branches: [CENTRO, SHOWROOM, CERRADA], isLoading: false, isError: false })
})

describe("BranchSelect — los usos actuales no cambian", () => {
  it("plan con módulo: ofrece 'Sin sucursal (general)' y todas las sucursales activas, cerradas incluidas", () => {
    render(<BranchSelect value={null} onChange={vi.fn()} />)
    const options = screen.getAllByRole("option").map((o) => o.textContent)
    expect(options).toEqual(["Sin sucursal (general)", "Centro", "Showroom", "Depósito viejo"])
  })

  it("plan SIN módulo de sucursales: no renderiza nada", () => {
    usePlanLimitsMock.mockReturnValue({ limits: { hasBranchesModule: false } })
    const { container } = render(<BranchSelect value={null} onChange={vi.fn()} />)
    expect(container).toBeEmptyDOMElement()
  })

  it("límites todavía sin resolver: no renderiza nada (como hoy)", () => {
    usePlanLimitsMock.mockReturnValue({ limits: undefined })
    const { container } = render(<BranchSelect value={null} onChange={vi.fn()} />)
    expect(container).toBeEmptyDOMElement()
  })

  it("elegir 'Sin sucursal' devuelve null", async () => {
    const onChange = vi.fn()
    render(<BranchSelect value="b-centro" onChange={onChange} />)
    await userEvent.click(screen.getByRole("option", { name: "Sin sucursal (general)" }))
    expect(onChange).toHaveBeenCalledWith(null)
  })

  it("elegir una sucursal devuelve su id", async () => {
    const onChange = vi.fn()
    render(<BranchSelect value={null} onChange={onChange} />)
    await userEvent.click(screen.getByRole("option", { name: "Showroom" }))
    expect(onChange).toHaveBeenCalledWith("b-show")
  })

  it("el placeholder por defecto sigue siendo 'Sin sucursal (general)'", () => {
    render(<BranchSelect value={null} onChange={vi.fn()} />)
    expect(screen.getByTestId("placeholder")).toHaveTextContent("Sin sucursal (general)")
  })
})

describe("BranchSelect required — la sucursal es obligatoria (remito)", () => {
  it("no ofrece 'Sin sucursal' y deja afuera las sucursales cerradas", () => {
    render(<BranchSelect value={null} onChange={vi.fn()} required alwaysVisible />)
    const options = screen.getAllByRole("option").map((o) => o.textContent)
    expect(options).toEqual(["Centro", "Showroom"])
    expect(options).not.toContain("Sin sucursal (general)")
    expect(options).not.toContain("Depósito viejo")
  })

  it("sin valor muestra el placeholder de elegir ('Elegí la sucursal'), no 'Sin sucursal'", () => {
    render(<BranchSelect value={null} onChange={vi.fn()} required alwaysVisible />)
    expect(screen.getByTestId("placeholder")).toHaveTextContent("Elegí la sucursal")
  })

  it("un placeholder explícito manda sobre el de required", () => {
    render(<BranchSelect value={null} onChange={vi.fn()} required alwaysVisible placeholder="Sale de…" />)
    expect(screen.getByTestId("placeholder")).toHaveTextContent("Sale de…")
  })

  it("elegir una sucursal devuelve su id (nunca null)", async () => {
    const onChange = vi.fn()
    render(<BranchSelect value={null} onChange={onChange} required alwaysVisible />)
    await userEvent.click(screen.getByRole("option", { name: "Centro" }))
    expect(onChange).toHaveBeenCalledWith("b-centro")
    expect(onChange).not.toHaveBeenCalledWith(null)
  })

  it("con una sucursal elegida el valor del Select es su id (no el centinela de 'sin sucursal')", () => {
    render(<BranchSelect value="b-show" onChange={vi.fn()} required alwaysVisible />)
    expect(screen.getByTestId("select")).toHaveAttribute("data-value", "b-show")
  })

  it("sin valor el Select no usa el centinela '__none__' (no hay opción que lo respalde)", () => {
    render(<BranchSelect value={null} onChange={vi.fn()} required alwaysVisible />)
    expect(screen.getByTestId("select")).not.toHaveAttribute("data-value", "__none__")
  })
})

describe("BranchSelect alwaysVisible — plan sin módulo de sucursales", () => {
  beforeEach(() => {
    usePlanLimitsMock.mockReturnValue({ limits: { hasBranchesModule: false } })
  })

  it("se muestra aunque el plan no tenga el módulo", () => {
    render(<BranchSelect value={null} onChange={vi.fn()} alwaysVisible />)
    expect(screen.getByRole("combobox")).toBeInTheDocument()
    expect(screen.getAllByRole("option").map((o) => o.textContent)).toContain("Centro")
  })

  it("se muestra incluso con los límites del plan todavía sin resolver", () => {
    usePlanLimitsMock.mockReturnValue({ limits: undefined })
    render(<BranchSelect value={null} onChange={vi.fn()} alwaysVisible />)
    expect(screen.getByRole("combobox")).toBeInTheDocument()
  })

  it("sola (sin required) conserva 'Sin sucursal': son props independientes", () => {
    render(<BranchSelect value={null} onChange={vi.fn()} alwaysVisible />)
    expect(screen.getAllByRole("option").map((o) => o.textContent)).toContain("Sin sucursal (general)")
  })

  it("required sin alwaysVisible sigue oculto en un plan sin módulo (props independientes)", () => {
    const { container } = render(<BranchSelect value={null} onChange={vi.fn()} required />)
    expect(container).toBeEmptyDOMElement()
  })
})

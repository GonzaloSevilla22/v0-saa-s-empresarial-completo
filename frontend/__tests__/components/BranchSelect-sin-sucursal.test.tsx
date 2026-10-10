/**
 * ventas-sucursal-por-defecto (D9, tarea 6.1) — `BranchSelect` suma tres props
 * ADITIVAS que dejan a compra, gasto e importador de gastos idénticos:
 *
 *   - `allowUnassigned` (por defecto `true`): con `false` desaparece la opción
 *     «Sin sucursal (general)» y el selector muestra la sucursal PRINCIPAL ya
 *     elegida, rotulada «Nombre (principal)». El estado del formulario sigue en
 *     `null` hasta que el usuario elige otra: viaja `null` y el SERVIDOR resuelve
 *     la principal con datos vivos (D1).
 *   - `label`: el rótulo vive DENTRO del componente (patrón de
 *     `PaymentMethodSelect`), con `useId`, `<Label htmlFor>` e `id` en el disparador:
 *     sin el módulo de sucursales desaparece junto con el control.
 *   - `fallbackBranchId`: la sucursal que el SERVIDOR va a usar cuando no es la
 *     principal (por ejemplo, la del documento de origen). Sólo cambia el valor
 *     mostrado con el estado en `null`; no se emite por `onChange`.
 *
 * A diferencia de BranchSelect.test.tsx (que sustituye `ui/select` por dobles
 * planos), acá se usa el Select de Radix REAL: hace falta para probar que elegir
 * la principal que ya se muestra NO emite `onChange` (Radix sólo emite cuando el
 * valor cambia) y para que `getByLabelText` encuentre el disparador por su `id`.
 * Los hooks de plan y sucursales se mockean.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { BranchSelect } from "@/components/branches/BranchSelect"
import type { Branch } from "@/lib/types"

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
const CERRADA = branch({ id: "b-cerrada", name: "Depósito viejo", status: "closed", createdAt: "2025-06-01T00:00:00Z" })

beforeEach(() => {
  vi.clearAllMocks()
  usePlanLimitsMock.mockReturnValue({ limits: { hasBranchesModule: true } })
  useBranchesMock.mockReturnValue({ branches: [CENTRO, SHOWROOM], isLoading: false, isError: false })
})

describe("BranchSelect con allowUnassigned={false} — la principal a la vista", () => {
  it("muestra la principal preseleccionada y rotulada «(principal)», sin «Sin sucursal»", async () => {
    const user = userEvent.setup()
    render(<BranchSelect value={null} onChange={vi.fn()} allowUnassigned={false} label="Sucursal" />)

    const trigger = screen.getByRole("combobox", { name: "Sucursal" })
    expect(trigger).toHaveTextContent("Centro (principal)")
    expect(trigger).not.toHaveTextContent(/sin sucursal/i)

    await user.click(trigger)
    const options = within(await screen.findByRole("listbox")).getAllByRole("option").map((o) => o.textContent)
    expect(options).toEqual(["Centro (principal)", "Showroom"])
  })

  it("elegir OTRA sucursal emite su id", async () => {
    const onChange = vi.fn()
    const user = userEvent.setup()
    render(<BranchSelect value={null} onChange={onChange} allowUnassigned={false} label="Sucursal" />)

    await user.click(screen.getByRole("combobox", { name: "Sucursal" }))
    await user.click(await screen.findByRole("option", { name: "Showroom" }))

    expect(onChange).toHaveBeenCalledTimes(1)
    expect(onChange).toHaveBeenCalledWith("b-show")
  })

  it("elegir la principal que YA se muestra no emite onChange (Radix sólo emite cuando el valor cambia): el estado sigue en null", async () => {
    const onChange = vi.fn()
    const user = userEvent.setup()
    render(<BranchSelect value={null} onChange={onChange} allowUnassigned={false} label="Sucursal" />)

    await user.click(screen.getByRole("combobox", { name: "Sucursal" }))
    await user.click(await screen.findByRole("option", { name: "Centro (principal)" }))

    expect(onChange).not.toHaveBeenCalled()
  })

  it("con un valor explícito muestra ESA sucursal, y la principal sigue rotulada en la lista", async () => {
    const user = userEvent.setup()
    render(<BranchSelect value="b-show" onChange={vi.fn()} allowUnassigned={false} label="Sucursal" />)

    const trigger = screen.getByRole("combobox", { name: "Sucursal" })
    expect(trigger).toHaveTextContent("Showroom")
    expect(trigger).not.toHaveTextContent("(principal)")

    await user.click(trigger)
    expect(await screen.findByRole("option", { name: "Centro (principal)" })).toBeInTheDocument()
  })

  it("con la más antigua CERRADA, la principal mostrada es la siguiente operativa (espejo de c26_default_branch)", () => {
    useBranchesMock.mockReturnValue({ branches: [CERRADA, CENTRO, SHOWROOM], isLoading: false, isError: false })
    render(<BranchSelect value={null} onChange={vi.fn()} allowUnassigned={false} label="Sucursal" />)

    expect(screen.getByRole("combobox", { name: "Sucursal" })).toHaveTextContent("Centro (principal)")
  })

  it("fallbackBranchId: con el estado en null se muestra la sucursal que el servidor va a usar, no la principal", async () => {
    const user = userEvent.setup()
    render(
      <BranchSelect value={null} onChange={vi.fn()} allowUnassigned={false} label="Sucursal" fallbackBranchId="b-show" />,
    )

    const trigger = screen.getByRole("combobox", { name: "Sucursal" })
    expect(trigger).toHaveTextContent("Showroom")
    expect(trigger).not.toHaveTextContent("Centro")

    await user.click(trigger)
    // la principal sigue marcada en la lista: el rótulo es de la principal, no de lo mostrado
    expect(await screen.findByRole("option", { name: "Centro (principal)" })).toBeInTheDocument()
  })

  it("fallbackBranchId no pisa un valor explícito", () => {
    render(
      <BranchSelect value="b-centro" onChange={vi.fn()} allowUnassigned={false} label="Sucursal" fallbackBranchId="b-show" />,
    )
    expect(screen.getByRole("combobox", { name: "Sucursal" })).toHaveTextContent("Centro (principal)")
  })

  it("mientras las sucursales cargan, el disparador no dice «Sin sucursal»", () => {
    useBranchesMock.mockReturnValue({ branches: [], isLoading: true, isError: false })
    render(<BranchSelect value={null} onChange={vi.fn()} allowUnassigned={false} label="Sucursal" />)

    const trigger = screen.getByRole("combobox", { name: "Sucursal" })
    expect(trigger).toHaveTextContent("Cargando sucursales…")
    expect(trigger).not.toHaveTextContent(/sin sucursal/i)
  })
})

describe("BranchSelect — rótulo propio", () => {
  it("el disparador se encuentra por su rótulo (htmlFor/id)", () => {
    render(<BranchSelect value={null} onChange={vi.fn()} allowUnassigned={false} label="Sucursal" />)
    expect(screen.getByLabelText("Sucursal")).toBe(screen.getByRole("combobox"))
  })

  it("sin el módulo de sucursales no se renderiza ni el rótulo ni el control", () => {
    usePlanLimitsMock.mockReturnValue({ limits: { hasBranchesModule: false } })
    const { container } = render(<BranchSelect value={null} onChange={vi.fn()} allowUnassigned={false} label="Sucursal" />)

    expect(container).toBeEmptyDOMElement()
    expect(screen.queryByText("Sucursal")).not.toBeInTheDocument()
  })

  it("sin `label` el comportamiento es el de siempre: no agrega ningún rótulo", () => {
    render(<BranchSelect value={null} onChange={vi.fn()} />)
    expect(screen.queryByText("Sucursal")).not.toBeInTheDocument()
    expect(screen.getByRole("combobox")).toHaveTextContent("Sin sucursal (general)")
  })
})

describe("BranchSelect con allowUnassigned (por defecto true) — compra, gasto e importador no cambian", () => {
  it("conserva «Sin sucursal (general)» como primera opción y NO marca ninguna como principal", async () => {
    const user = userEvent.setup()
    render(<BranchSelect value={null} onChange={vi.fn()} />)

    await user.click(screen.getByRole("combobox"))
    const options = within(await screen.findByRole("listbox")).getAllByRole("option").map((o) => o.textContent)
    expect(options).toEqual(["Sin sucursal (general)", "Centro", "Showroom"])
  })

  it("elegir «Sin sucursal» sigue emitiendo null", async () => {
    const onChange = vi.fn()
    const user = userEvent.setup()
    render(<BranchSelect value="b-centro" onChange={onChange} />)

    await user.click(screen.getByRole("combobox"))
    await user.click(await screen.findByRole("option", { name: "Sin sucursal (general)" }))

    expect(onChange).toHaveBeenCalledWith(null)
  })
})

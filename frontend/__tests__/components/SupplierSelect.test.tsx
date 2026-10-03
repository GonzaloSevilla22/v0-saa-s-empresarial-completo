/**
 * remitos-compra (D11, tarea 4.3) — `components/suppliers/SupplierSelect.tsx`,
 * extraído de `purchase-form.tsx` SIN cambiar lo que muestra: selector buscable de
 * proveedor + "Nuevo proveedor" en el lugar, que queda seleccionado. La prop
 * `askPhone` (default `false` = lo que ya mostraba `purchase-form`) suma un
 * teléfono opcional al alta inline: el WhatsApp al proveedor del remito depende
 * de ese número (hoy 2 de 19 proveedores lo tienen).
 *
 * Mocks: `useSuppliers`, `sonner`, `SearchableSelect` (expone `data-value` y un
 * botón por opción para elegir y limpiar, como los tests de purchase-form).
 */
import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"
import { toast } from "sonner"
import { SupplierSelect } from "@/components/suppliers/SupplierSelect"

const addSupplierMock = vi.fn()
let suppliersMock: Array<{ id: string; name: string }> = []

vi.mock("@/hooks/data/use-suppliers", () => ({
  useSuppliers: () => ({
    suppliers: suppliersMock,
    addSupplier: addSupplierMock,
    isLoading: false,
    isError: false,
  }),
}))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))
vi.mock("@/components/ui/searchable-select", () => ({
  SearchableSelect: ({
    options,
    value,
    onValueChange,
    placeholder,
    "aria-labelledby": labelledBy,
  }: {
    options: Array<{ value: string; label: string }>
    value: string
    onValueChange: (v: string) => void
    placeholder?: string
    "aria-labelledby"?: string
  }) => (
    <div data-testid="searchable-select" data-value={value} data-placeholder={placeholder} data-labelledby={labelledBy}>
      {options.map((o) => (
        <button key={o.value} type="button" data-testid={`supplier-option-${o.value}`} onClick={() => onValueChange(o.value)}>
          {o.label}
        </button>
      ))}
      <button type="button" data-testid="supplier-clear" onClick={() => onValueChange("")}>
        limpiar
      </button>
    </div>
  ),
}))

afterEach(() => {
  vi.clearAllMocks()
  suppliersMock = []
})

function openInlineCreate() {
  fireEvent.click(screen.getByRole("button", { name: /nuevo proveedor/i }))
}

describe("SupplierSelect — selector buscable", () => {
  it("muestra el rótulo 'Proveedor' y enlaza el selector por aria-labelledby con el id pedido", () => {
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Andina" }]
    render(<SupplierSelect value={null} onChange={vi.fn()} labelId="remito-supplier-label" />)

    expect(screen.getByText("Proveedor")).toHaveAttribute("id", "remito-supplier-label")
    expect(screen.getByTestId("searchable-select")).toHaveAttribute("data-labelledby", "remito-supplier-label")
  })

  it("sin labelId genera uno propio y lo enlaza igual (dos selectores en la misma página no chocan)", () => {
    render(
      <>
        <SupplierSelect value={null} onChange={vi.fn()} />
        <SupplierSelect value={null} onChange={vi.fn()} />
      </>,
    )
    const labels = screen.getAllByText("Proveedor")
    const selects = screen.getAllByTestId("searchable-select")
    expect(labels[0].id).not.toBe("")
    expect(labels[0].id).not.toBe(labels[1].id)
    expect(selects[0]).toHaveAttribute("data-labelledby", labels[0].id)
    expect(selects[1]).toHaveAttribute("data-labelledby", labels[1].id)
  })

  it("el placeholder es el de siempre", () => {
    render(<SupplierSelect value={null} onChange={vi.fn()} />)
    expect(screen.getByTestId("searchable-select")).toHaveAttribute("data-placeholder", "Seleccionar proveedor")
  })

  it("el valor entra tal cual y vacío cuando no hay proveedor", () => {
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Andina" }]
    const { rerender } = render(<SupplierSelect value="sup-1" onChange={vi.fn()} />)
    expect(screen.getByTestId("searchable-select")).toHaveAttribute("data-value", "sup-1")
    rerender(<SupplierSelect value={null} onChange={vi.fn()} />)
    expect(screen.getByTestId("searchable-select")).toHaveAttribute("data-value", "")
  })

  it("elegir un proveedor avisa con su id; limpiar avisa con null", () => {
    suppliersMock = [
      { id: "sup-1", name: "Distribuidora Andina" },
      { id: "sup-2", name: "Envases del Oeste" },
    ]
    const onChange = vi.fn()
    render(<SupplierSelect value={null} onChange={onChange} />)

    fireEvent.click(screen.getByTestId("supplier-option-sup-2"))
    expect(onChange).toHaveBeenLastCalledWith("sup-2")
    fireEvent.click(screen.getByTestId("supplier-clear"))
    expect(onChange).toHaveBeenLastCalledWith(null)
  })

  it("muestra el aviso de proveedor no resoluble sólo cuando el caller lo pide", () => {
    const { rerender } = render(<SupplierSelect value="sup-viejo" onChange={vi.fn()} unresolvedHint="Proveedor actual no disponible (dado de baja)" />)
    expect(screen.getByText("Proveedor actual no disponible (dado de baja)")).toBeInTheDocument()
    rerender(<SupplierSelect value="sup-viejo" onChange={vi.fn()} unresolvedHint={null} />)
    expect(screen.queryByText(/dado de baja/i)).not.toBeInTheDocument()
  })
})

describe("SupplierSelect — alta inline sin teléfono (default, como purchase-form)", () => {
  it("'Nuevo proveedor' muestra sólo el nombre; 'Cancelar' vuelve al selector", () => {
    render(<SupplierSelect value={null} onChange={vi.fn()} />)
    openInlineCreate()

    expect(screen.getByPlaceholderText(/nombre del proveedor/i)).toBeInTheDocument()
    expect(screen.queryByPlaceholderText(/tel[eé]fono/i)).not.toBeInTheDocument()
    expect(screen.queryByTestId("searchable-select")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: /cancelar/i }))
    expect(screen.getByTestId("searchable-select")).toBeInTheDocument()
  })

  it("crea el proveedor (nombre recortado, sin email ni teléfono), lo selecciona y vuelve al selector", async () => {
    addSupplierMock.mockResolvedValueOnce({ id: "sup-new", name: "Nuevo Proveedor" })
    const onChange = vi.fn()
    render(<SupplierSelect value={null} onChange={onChange} />)
    openInlineCreate()

    fireEvent.change(screen.getByPlaceholderText(/nombre del proveedor/i), { target: { value: "  Nuevo Proveedor  " } })
    fireEvent.click(screen.getByRole("button", { name: /crear y seleccionar/i }))

    await vi.waitFor(() => expect(onChange).toHaveBeenCalledWith("sup-new"))
    expect(addSupplierMock).toHaveBeenCalledWith({ name: "Nuevo Proveedor", email: "", phone: "" })
    expect(toast.success).toHaveBeenCalledWith('Proveedor "  Nuevo Proveedor  " creado')
    await vi.waitFor(() => expect(screen.getByTestId("searchable-select")).toBeInTheDocument())
  })

  it("sin nombre no llama al servidor y avisa", () => {
    render(<SupplierSelect value={null} onChange={vi.fn()} />)
    openInlineCreate()
    fireEvent.click(screen.getByRole("button", { name: /crear y seleccionar/i }))

    expect(addSupplierMock).not.toHaveBeenCalled()
    expect(toast.error).toHaveBeenCalledWith("El nombre del proveedor es obligatorio")
  })

  it("si el alta falla, avisa con el mensaje del error y no selecciona nada", async () => {
    addSupplierMock.mockRejectedValueOnce(new Error("Ya existe un proveedor con ese nombre"))
    const onChange = vi.fn()
    render(<SupplierSelect value={null} onChange={onChange} />)
    openInlineCreate()
    fireEvent.change(screen.getByPlaceholderText(/nombre del proveedor/i), { target: { value: "Andina" } })
    fireEvent.click(screen.getByRole("button", { name: /crear y seleccionar/i }))

    await vi.waitFor(() => expect(toast.error).toHaveBeenCalledWith("Ya existe un proveedor con ese nombre"))
    expect(onChange).not.toHaveBeenCalled()
  })
})

describe("SupplierSelect — askPhone: el alta inline suma un teléfono opcional", () => {
  it("muestra el campo de teléfono junto al nombre", () => {
    render(<SupplierSelect value={null} onChange={vi.fn()} askPhone />)
    openInlineCreate()
    expect(screen.getByPlaceholderText(/nombre del proveedor/i)).toBeInTheDocument()
    expect(screen.getByPlaceholderText(/tel[eé]fono \(opcional\)/i)).toBeInTheDocument()
  })

  it("manda el teléfono recortado al alta y selecciona al proveedor", async () => {
    addSupplierMock.mockResolvedValueOnce({ id: "sup-tel", name: "Andina" })
    const onChange = vi.fn()
    render(<SupplierSelect value={null} onChange={onChange} askPhone />)
    openInlineCreate()
    fireEvent.change(screen.getByPlaceholderText(/nombre del proveedor/i), { target: { value: "Andina" } })
    fireEvent.change(screen.getByPlaceholderText(/tel[eé]fono \(opcional\)/i), { target: { value: " 261 555 1234 " } })
    fireEvent.click(screen.getByRole("button", { name: /crear y seleccionar/i }))

    await vi.waitFor(() => expect(onChange).toHaveBeenCalledWith("sup-tel"))
    expect(addSupplierMock).toHaveBeenCalledWith({ name: "Andina", email: "", phone: "261 555 1234" })
  })

  it("el teléfono es opcional: vacío se manda como texto vacío y el alta sigue", async () => {
    addSupplierMock.mockResolvedValueOnce({ id: "sup-sin-tel", name: "Andina" })
    const onChange = vi.fn()
    render(<SupplierSelect value={null} onChange={onChange} askPhone />)
    openInlineCreate()
    fireEvent.change(screen.getByPlaceholderText(/nombre del proveedor/i), { target: { value: "Andina" } })
    fireEvent.click(screen.getByRole("button", { name: /crear y seleccionar/i }))

    await vi.waitFor(() => expect(onChange).toHaveBeenCalledWith("sup-sin-tel"))
    expect(addSupplierMock).toHaveBeenCalledWith({ name: "Andina", email: "", phone: "" })
  })

  it("el campo de teléfono es de tipo tel y tiene nombre accesible propio", () => {
    render(<SupplierSelect value={null} onChange={vi.fn()} askPhone />)
    openInlineCreate()
    const phone = screen.getByRole("textbox", { name: /tel[eé]fono del proveedor/i })
    expect(phone).toHaveAttribute("type", "tel")
  })

  it("al cerrar y volver a abrir el alta, los campos arrancan vacíos", async () => {
    addSupplierMock.mockResolvedValueOnce({ id: "sup-1", name: "Andina" })
    render(<SupplierSelect value={null} onChange={vi.fn()} askPhone />)
    openInlineCreate()
    fireEvent.change(screen.getByPlaceholderText(/nombre del proveedor/i), { target: { value: "Andina" } })
    fireEvent.change(screen.getByPlaceholderText(/tel[eé]fono \(opcional\)/i), { target: { value: "261" } })
    fireEvent.click(screen.getByRole("button", { name: /crear y seleccionar/i }))
    await vi.waitFor(() => expect(screen.getByTestId("searchable-select")).toBeInTheDocument())

    openInlineCreate()
    expect(screen.getByPlaceholderText(/nombre del proveedor/i)).toHaveValue("")
    expect(screen.getByPlaceholderText(/tel[eé]fono \(opcional\)/i)).toHaveValue("")
  })
})

// ── remitos-compra (tarea 5.1): el proveedor congelado de un remito ya recibido ──

describe("SupplierSelect — frozenOption (proveedor dado de baja que sigue en el remito)", () => {
  it("suma la opción congelada a la lista para que el valor resuelva en vez de caer al placeholder", () => {
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Andina" }]
    render(
      <SupplierSelect
        value="sup-viejo"
        onChange={vi.fn()}
        frozenOption={{ value: "sup-viejo", label: "Proveedor Viejo (dado de baja)" }}
      />,
    )
    expect(screen.getByTestId("supplier-option-sup-viejo")).toHaveTextContent("Proveedor Viejo (dado de baja)")
    expect(screen.getByTestId("supplier-option-sup-1")).toBeInTheDocument()
    expect(screen.getByTestId("searchable-select")).toHaveAttribute("data-value", "sup-viejo")
  })

  it("no la duplica si el proveedor sigue en la lista", () => {
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Andina" }]
    render(<SupplierSelect value="sup-1" onChange={vi.fn()} frozenOption={{ value: "sup-1", label: "Otro rótulo" }} />)
    expect(screen.getAllByTestId("supplier-option-sup-1")).toHaveLength(1)
    expect(screen.getByTestId("supplier-option-sup-1")).toHaveTextContent("Distribuidora Andina")
  })

  it("sin la prop la lista es la de siempre", () => {
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Andina" }]
    render(<SupplierSelect value={null} onChange={vi.fn()} />)
    expect(screen.getAllByTestId(/^supplier-option-/)).toHaveLength(1)
  })

  it("elegir otro proveedor desde la opción congelada avisa con el id nuevo", () => {
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Andina" }]
    const onChange = vi.fn()
    render(
      <SupplierSelect
        value="sup-viejo"
        onChange={onChange}
        frozenOption={{ value: "sup-viejo", label: "Proveedor Viejo (dado de baja)" }}
      />,
    )
    fireEvent.click(screen.getByTestId("supplier-option-sup-1"))
    expect(onChange).toHaveBeenCalledWith("sup-1")
  })
})

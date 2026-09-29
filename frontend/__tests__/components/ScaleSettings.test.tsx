/**
 * balanza-etiquetas-pos (task 9.1 RED → 9.2/9.3 GREEN) — `ScaleSettings.tsx`,
 * pestaña "Balanza" de /configuracion (D11):
 *  - interruptor global; editor por formato (peso/unidad/varios) con
 *    "Resultado" en vivo y errores D4 en línea; restaurar de fábrica;
 *  - importe máximo + aviso de desborde;
 *  - probador contra la configuración EN EDICIÓN (funciona aunque la
 *    lectura esté deshabilitada);
 *  - guía con los pasos literales y sus páginas;
 *  - seller en sólo lectura (probador y exportación habilitados);
 *  - exportación con `buildScaleCsv` + `downloadTextFile`, sin `generate-export`.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import "@testing-library/jest-dom"
import { FACTORY_SCALE_SETTINGS, type ScaleSettings as ScaleSettingsType } from "@/lib/scale-layout"
import type { Product, UnitOfMeasure } from "@/lib/types"

let scaleSettingsFixture: ScaleSettingsType = FACTORY_SCALE_SETTINGS
const updateMock = vi.fn()
let roleFixture: "owner" | "admin" | "member" = "owner"

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const UNIT: UnitOfMeasure = { id: "u-un", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }
const UNITS = [KG, UNIT]

const TOMATE: Product = {
  id: "p-tomate", name: "Tomate", category: "Verdulería",
  cost: 2, price: 4.8, margin: 40, stock: 10, minStock: 0,
  isVariant: false, stockControlType: "tracked", baseUnitId: "u-kg", scalePlu: 261,
}
let productsFixture: Product[] = [TOMATE]

vi.mock("@/hooks/data/use-scale-settings", () => ({
  useScaleSettings: () => ({ settings: scaleSettingsFixture, isLoading: false, isError: false, error: null }),
  useUpdateScaleSettings: () => ({ mutateAsync: updateMock, isPending: false }),
}))
vi.mock("@/hooks/useOrgRole", () => ({
  useOrgRole: () => ({ role: roleFixture, roles: [roleFixture], isWriter: true, isLoading: false }),
}))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: productsFixture }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: UNITS }) }))
vi.mock("@/hooks/data/use-product-categories", () => ({
  useProductCategories: () => ({ productCategories: [], isLoading: false }),
}))
vi.mock("@/lib/excel", () => ({ downloadTextFile: vi.fn() }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

const { ScaleSettings } = await import("@/components/settings/ScaleSettings")

beforeEach(() => {
  vi.clearAllMocks()
  scaleSettingsFixture = FACTORY_SCALE_SETTINGS
  productsFixture = [TOMATE]
  roleFixture = "owner"
  updateMock.mockResolvedValue(undefined)
})

describe("ScaleSettings — interruptor y guardar", () => {
  it("muestra el interruptor global y lo refleja al estado persistido", () => {
    render(<ScaleSettings />)
    expect(screen.getByText(/leer etiquetas de balanza/i)).toBeInTheDocument()
    const toggle = screen.getByRole("switch", { name: /leer etiquetas de balanza/i })
    expect(toggle).toHaveAttribute("aria-checked", "false")
  })

  it("guardar llama al PUT con la configuración editada", async () => {
    render(<ScaleSettings />)
    fireEvent.click(screen.getByRole("switch", { name: /leer etiquetas de balanza/i }))
    fireEvent.click(screen.getByRole("button", { name: /guardar/i }))
    await waitFor(() => expect(updateMock).toHaveBeenCalled())
    expect(updateMock.mock.calls[0][0].enabled).toBe(true)
  })

  it("muestra el error del backend al guardar", async () => {
    updateMock.mockRejectedValueOnce(new Error("Venta por peso: los campos deben sumar 12 dígitos (suman 10)."))
    render(<ScaleSettings />)
    fireEvent.click(screen.getByRole("button", { name: /guardar/i }))
    await waitFor(() =>
      expect(screen.getByText(/los campos deben sumar 12 dígitos/i)).toBeInTheDocument(),
    )
  })
})

describe("ScaleSettings — editor de formatos (D4)", () => {
  it("muestra el Resultado en vivo del formato de peso de fábrica", () => {
    render(<ScaleSettings />)
    expect(screen.getByText("20BBBBCCCCCCX")).toBeInTheDocument()
  })

  it("cambiar los dígitos del campo Código actualiza el Resultado en vivo", () => {
    render(<ScaleSettings />)
    const digitsInputs = screen.getAllByLabelText(/dígitos.*campo b.*peso/i)
    fireEvent.change(digitsInputs[0], { target: { value: "3" } })
    expect(screen.getByText("20BBBCCCCCCX")).toBeInTheDocument()
  })

  it("un formato que no suma 12 dígitos muestra el error D4 en línea y deshabilita Guardar", () => {
    render(<ScaleSettings />)
    const digitsInputs = screen.getAllByLabelText(/dígitos.*campo b.*peso/i)
    fireEvent.change(digitsInputs[0], { target: { value: "1" } })
    expect(screen.getByText(/12 dígitos/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /guardar/i })).toBeDisabled()
  })

  it("restaurar valores de fábrica vuelve al Resultado de fábrica tras editar", () => {
    render(<ScaleSettings />)
    const digitsInputs = screen.getAllByLabelText(/dígitos.*campo b.*peso/i)
    fireEvent.change(digitsInputs[0], { target: { value: "1" } })
    expect(screen.queryByText("20BBBBCCCCCCX")).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: /restaurar valores de fábrica/i }))
    expect(screen.getByText("20BBBBCCCCCCX")).toBeInTheDocument()
  })

  it("muestra el importe máximo representable del formato de peso", () => {
    render(<ScaleSettings />)
    expect(screen.getAllByText(/9\.999,99/).length).toBeGreaterThan(0)
  })

  it("avisa cuando un producto con PLU supera el importe máximo representable", () => {
    productsFixture = [{ ...TOMATE, price: 12000 }]
    render(<ScaleSettings />)
    expect(screen.getByText(/tomate/i)).toBeInTheDocument()
    expect(screen.getByText(/supera el importe máximo/i)).toBeInTheDocument()
  })
})

describe("ScaleSettings — probador", () => {
  it("decodifica contra la configuración EN EDICIÓN, aunque la lectura esté deshabilitada", () => {
    render(<ScaleSettings />)
    // fábrica: enabled=false a nivel cuenta — el probador igual decodifica.
    const input = screen.getByLabelText(/código a probar/i)
    fireEvent.change(input, { target: { value: "2002610013638" } })
    fireEvent.click(screen.getByRole("button", { name: /^probar$/i }))
    expect(screen.getByText(/tomate/i)).toBeInTheDocument()
    expect(screen.getByText(/la lectura está deshabilitada/i)).toBeInTheDocument()
  })

  it("muestra PLU, valor decodificado y el subtotal de la línea que se agregaría", () => {
    render(<ScaleSettings />)
    const input = screen.getByLabelText(/código a probar/i)
    fireEvent.change(input, { target: { value: "2002610013638" } })
    fireEvent.click(screen.getByRole("button", { name: /^probar$/i }))
    expect(screen.getByText(/261/)).toBeInTheDocument()
    expect(screen.getAllByText(/13,63/).length).toBeGreaterThan(0)
  })

  it("muestra el motivo de un código inválido (dígito verificador faltante)", () => {
    render(<ScaleSettings />)
    const input = screen.getByLabelText(/código a probar/i)
    fireEvent.change(input, { target: { value: "200261001363" } })
    fireEvent.click(screen.getByRole("button", { name: /^probar$/i }))
    expect(screen.getByText(/no envía el dígito verificador/i)).toBeInTheDocument()
  })

  it("muestra el motivo not_scale (no coincide ninguna cabecera)", () => {
    render(<ScaleSettings />)
    const input = screen.getByLabelText(/código a probar/i)
    fireEvent.change(input, { target: { value: "2702610013637" } })
    fireEvent.click(screen.getByRole("button", { name: /^probar$/i }))
    expect(screen.getByText(/ninguna cabecera configurada coincide/i)).toBeInTheDocument()
  })

  it("el input del probador tiene Label asociado y el resultado vive en una región aria-live", () => {
    render(<ScaleSettings />)
    const input = screen.getByLabelText(/código a probar/i)
    expect(input.tagName).toBe("INPUT")
    fireEvent.change(input, { target: { value: "2002610013638" } })
    fireEvent.click(screen.getByRole("button", { name: /^probar$/i }))
    expect(screen.getByRole("status")).toBeInTheDocument()
  })
})

describe("ScaleSettings — exportación", () => {
  it("el botón de exportar no llama a generate-export ni toca la cuota", async () => {
    const { downloadTextFile } = await import("@/lib/excel")
    render(<ScaleSettings />)
    fireEvent.click(screen.getByRole("button", { name: /exportar catálogo para la balanza/i }))
    await waitFor(() => expect(downloadTextFile).toHaveBeenCalled())
    const [, filename] = vi.mocked(downloadTextFile).mock.calls[0]
    expect(filename).toMatch(/^balanza-aliadata-\d{4}-\d{2}-\d{2}\.csv$/)
  })

  it("muestra el resumen de exportados tras exportar", async () => {
    render(<ScaleSettings />)
    fireEvent.click(screen.getByRole("button", { name: /exportar catálogo para la balanza/i }))
    await waitFor(() => expect(screen.getByText(/1 exportado/i)).toBeInTheDocument())
  })
})

describe("ScaleSettings — guía", () => {
  it("incluye los pasos literales del manual con sus páginas", () => {
    render(<ScaleSettings />)
    expect(screen.getByText(/134-135/)).toBeInTheDocument()
    expect(screen.getByText(/98/)).toBeInTheDocument()
    expect(screen.getByText(/71-72/)).toBeInTheDocument()
    expect(screen.getAllByText(/reemplazar plu por el número/i).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/rollo de etiquetas/i).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/papel continuo/i).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/genéricos/i).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/cabecera propia/i).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/lector de códigos/i).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/neo basic tools/i).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/ftp\/sftp/i).length).toBeGreaterThan(0)
  })
})

describe("ScaleSettings — seller en sólo lectura", () => {
  beforeEach(() => {
    roleFixture = "member"
  })

  it("deshabilita el interruptor, el editor y Guardar/Restaurar", () => {
    render(<ScaleSettings />)
    expect(screen.getByRole("switch", { name: /leer etiquetas de balanza/i })).toBeDisabled()
    expect(screen.getByRole("button", { name: /guardar/i })).toBeDisabled()
    expect(screen.getByRole("button", { name: /restaurar valores de fábrica/i })).toBeDisabled()
  })

  it("el probador sigue funcionando", () => {
    render(<ScaleSettings />)
    const input = screen.getByLabelText(/código a probar/i)
    fireEvent.change(input, { target: { value: "2002610013638" } })
    fireEvent.click(screen.getByRole("button", { name: /^probar$/i }))
    expect(screen.getByText(/tomate/i)).toBeInTheDocument()
  })

  it("la exportación sigue habilitada", () => {
    render(<ScaleSettings />)
    expect(screen.getByRole("button", { name: /exportar catálogo para la balanza/i })).not.toBeDisabled()
  })
})

// Pasada visual 11.2 (pantalla Balanza en móvil): a 375 px la fila
// "Guardar" + "Restaurar valores de fábrica" no wrappeaba y el segundo botón
// se salía del card (medido en Chromium: borde derecho en 393,7 px con el
// card terminando en 359 px; `document.scrollWidth` no lo delataba porque el
// contenedor del shell recorta). jsdom no mide layout: lo observable acá es
// el contrato de clases; la medición real vive en la pasada de Chromium.
describe("ScaleSettings — móvil (pasada visual 11.2)", () => {
  it("Guardar y Restaurar se apilan a ancho completo por debajo de sm y vuelven a fila desde sm", () => {
    render(<ScaleSettings />)
    const save = screen.getByRole("button", { name: /^guardar$/i })
    const restore = screen.getByRole("button", { name: /restaurar valores de fábrica/i })
    const row = restore.parentElement as HTMLElement
    expect(save.parentElement).toBe(row)
    expect(row).toHaveClass("flex-col", "sm:flex-row")
    expect(save).toHaveClass("w-full", "sm:w-auto")
    expect(restore).toHaveClass("w-full", "sm:w-auto")
  })

  it("los títulos de la guía que ocupan dos líneas quedan alineados a la izquierda, como los de una línea", () => {
    render(<ScaleSettings />)
    // El trigger del acordeón es un <button>: sin `text-left`, un título que
    // wrappea a 375 px ("Cómo llega el archivo a la balanza (págs. 113,
    // 118-119)") se centraba y rompía la columna de los demás.
    const triggers = screen.getAllByRole("button", { expanded: true })
    expect(triggers.length).toBeGreaterThanOrEqual(8)
    for (const t of triggers) expect(t).toHaveClass("text-left")
  })
})

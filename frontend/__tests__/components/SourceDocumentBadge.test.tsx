/**
 * remitos-venta (tanda B, 7.6, D13) — `SourceDocumentBadge`: el badge "Desde …"
 * de /ventas generalizado a los dos documentos de origen (presupuesto y remito),
 * sin un componente gemelo por documento.
 *
 * El badge formatea el número con la definición única
 * (`formatInternalDocumentNumber` / `formatDeliveryNoteNumber`) y arma el enlace
 * según el tipo de documento.
 */
import { describe, it, expect, vi } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"
import { SourceDocumentBadge } from "@/components/ventas/SourceDocumentBadge"

describe("SourceDocumentBadge", () => {
  it("presupuesto: 'Desde presupuesto P-00000012' con enlace a /presupuestos/<id>", () => {
    render(<SourceDocumentBadge kind="quote" documentId="q-9" documentNumber={12} />)
    const link = screen.getByRole("link", { name: "Desde presupuesto P-00000012" })
    expect(link).toHaveAttribute("href", "/presupuestos/q-9")
  })

  it("remito: 'Desde remito R-00000007' con enlace a /remitos/<id>", () => {
    render(<SourceDocumentBadge kind="delivery_note" documentId="dn-3" documentNumber={7} />)
    const link = screen.getByRole("link", { name: "Desde remito R-00000007" })
    expect(link).toHaveAttribute("href", "/remitos/dn-3")
  })

  it("un documento sin número enlaza igual y no inventa uno (los dos tipos)", () => {
    const { unmount } = render(<SourceDocumentBadge kind="quote" documentId="q-old" documentNumber={null} />)
    expect(screen.getByRole("link", { name: "Desde presupuesto" })).toHaveAttribute("href", "/presupuestos/q-old")
    unmount()
    render(<SourceDocumentBadge kind="delivery_note" documentId="dn-old" documentNumber={null} />)
    expect(screen.getByRole("link", { name: "Desde remito" })).toHaveAttribute("href", "/remitos/dn-old")
  })

  it("seguir el enlace no propaga el click ni la tecla a la fila clickeable que lo contiene", () => {
    const onRowClick = vi.fn()
    const onRowKey = vi.fn()
    render(
      <div onClick={onRowClick} onKeyDown={onRowKey}>
        <SourceDocumentBadge kind="delivery_note" documentId="dn-3" documentNumber={7} />
      </div>,
    )
    const link = screen.getByRole("link", { name: /desde remito/i })
    fireEvent.click(link)
    fireEvent.keyDown(link, { key: "Enter" })
    expect(onRowClick).not.toHaveBeenCalled()
    expect(onRowKey).not.toHaveBeenCalled()
  })

  it("el nombre accesible completo queda en el title aunque la etiqueta se trunque", () => {
    render(<SourceDocumentBadge kind="delivery_note" documentId="dn-3" documentNumber={7} />)
    expect(screen.getByRole("link", { name: /desde remito/i })).toHaveAttribute("title", "Desde remito R-00000007")
  })
})

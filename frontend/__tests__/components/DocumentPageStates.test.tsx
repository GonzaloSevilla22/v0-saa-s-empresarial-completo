/**
 * remitos-venta (D11, tarea 4.9) — `components/shared/DocumentPageStates.tsx`:
 * `QuotePageStates` generalizado, con los textos parametrizados por documento
 * (cargando, error o no encontrado, sin permiso, no editable). El presupuesto
 * pasa a usarlo SIN cambiar lo que muestra (los tests de página existentes
 * siguen verdes sin tocarlos) y el remito lo usa con su redacción.
 */
import { describe, it, expect } from "vitest"
import { render, screen } from "@testing-library/react"
import {
  DocumentLoadError,
  DocumentLoading,
  DocumentNoPermission,
  DocumentNotEditable,
  type DocumentPageTexts,
} from "@/components/shared/DocumentPageStates"
import { QuoteLoadError, QuoteLoading, QuoteNoPermission } from "@/components/quotes/QuotePageStates"

const REMITO: DocumentPageTexts = {
  singular: "remito",
  loadingLabel: "Cargando remito…",
  backHref: "/remitos",
  backLabel: "Volver a remitos",
  permissionHint: "Pedile a un administrador del negocio que te habilite como vendedor o encargado de depósito.",
}

describe("DocumentLoading", () => {
  it("es una región status con el texto del documento", () => {
    render(<DocumentLoading label={REMITO.loadingLabel} />)
    expect(screen.getByRole("status")).toHaveTextContent("Cargando remito…")
  })
})

describe("DocumentLoadError", () => {
  it("alert con 'No se pudo cargar el remito…' y vuelta al listado del documento", () => {
    render(<DocumentLoadError texts={REMITO} />)
    expect(screen.getByRole("alert")).toHaveTextContent(
      "No se pudo cargar el remito. Puede que no exista o que sea de otra cuenta.",
    )
    expect(screen.getByRole("link", { name: /volver a remitos/i })).toHaveAttribute("href", "/remitos")
  })
})

describe("DocumentNoPermission", () => {
  it("nombra la acción y la salida (quién habilita), sin alert: es informativo", () => {
    render(<DocumentNoPermission texts={REMITO} action="emitir remitos" />)
    expect(screen.getByRole("status")).toHaveTextContent(
      "Tu rol no permite emitir remitos. Pedile a un administrador del negocio que te habilite como vendedor o encargado de depósito.",
    )
    expect(screen.queryByRole("alert")).toBeNull()
    expect(screen.getByRole("link", { name: /volver a remitos/i })).toHaveAttribute("href", "/remitos")
  })
})

describe("DocumentNotEditable", () => {
  it("convertido: el mensaje y el enlace a la venta, más la vuelta al listado", () => {
    render(
      <DocumentNotEditable
        texts={REMITO}
        message="Este remito ya se convirtió en una venta. Para corregirlo, eliminá la venta: el remito vuelve a quedar pendiente."
        link={{ href: "/ventas/ordenes/so-1", label: "Ver la venta" }}
      />,
    )
    expect(screen.getByRole("status")).toHaveTextContent(/ya se convirtió en una venta/i)
    expect(screen.getByRole("link", { name: "Ver la venta" })).toHaveAttribute("href", "/ventas/ordenes/so-1")
    expect(screen.getByRole("link", { name: /volver a remitos/i })).toHaveAttribute("href", "/remitos")
  })

  it("anulado: el motivo como contenido, sin enlace extra", () => {
    render(
      <DocumentNotEditable texts={REMITO} message="El remito está anulado y no se puede editar.">
        <p>Motivo: se devolvió la mercadería</p>
      </DocumentNotEditable>,
    )
    expect(screen.getByRole("status")).toHaveTextContent("El remito está anulado y no se puede editar.")
    expect(screen.getByText("Motivo: se devolvió la mercadería")).toBeInTheDocument()
    expect(screen.getAllByRole("link")).toHaveLength(1)
  })
})

describe("QuotePageStates delega sin cambiar lo que muestra", () => {
  it("QuoteLoading: texto por defecto de siempre y personalizable", () => {
    const { rerender } = render(<QuoteLoading />)
    expect(screen.getByRole("status")).toHaveTextContent("Cargando presupuesto…")
    rerender(<QuoteLoading label="Abriendo…" />)
    expect(screen.getByRole("status")).toHaveTextContent("Abriendo…")
  })

  it("QuoteLoadError: el texto y el enlace de siempre", () => {
    render(<QuoteLoadError />)
    expect(screen.getByRole("alert")).toHaveTextContent(
      "No se pudo cargar el presupuesto. Puede que no exista o que sea de otra cuenta.",
    )
    expect(screen.getByRole("link", { name: /volver a presupuestos/i })).toHaveAttribute("href", "/presupuestos")
  })

  it("QuoteNoPermission: el texto y el enlace de siempre", () => {
    render(<QuoteNoPermission action="crear presupuestos" />)
    expect(screen.getByRole("status")).toHaveTextContent(
      "Tu rol no permite crear presupuestos. Pedile a un administrador del negocio que te habilite como vendedor.",
    )
    expect(screen.getByRole("link", { name: /volver a presupuestos/i })).toHaveAttribute("href", "/presupuestos")
  })
})

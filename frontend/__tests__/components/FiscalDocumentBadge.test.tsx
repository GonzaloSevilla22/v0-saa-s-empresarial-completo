import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import { FiscalDocumentBadge } from "@/components/fiscal/FiscalDocumentBadge"

// venta-editable-sin-cae: el badge gana el 4o estado terminal `voided`
// (comprobante ANULADO por editar o borrar su venta ANTES de que el pedido
// saliera hacia ARCA). No es un error —nunca llegó a ARCA— así que se muestra
// inerte, con tokens semánticos, no con el rojo de `rejected`.
//
// El `useEffect` de Realtime sólo abre canal mientras status === "pending_cae":
// un anulado NO debe suscribirse a nada. Eso se asserta abajo con el spy del
// cliente de Supabase, porque es lo que evita un canal por cada fila anulada
// del listado.

const channelSpy = vi.fn()
const removeChannelSpy = vi.fn()

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    channel: (...args: unknown[]) => {
      channelSpy(...args)
      const chan = {
        on: () => chan,
        subscribe: () => chan,
      }
      return chan
    },
    removeChannel: removeChannelSpy,
  }),
}))

describe("FiscalDocumentBadge — estado voided (venta-editable-sin-cae)", () => {
  it("renderiza 'Anulado' en modo compacto", () => {
    render(<FiscalDocumentBadge documentId="fd-1" initialStatus="voided" />)
    expect(screen.getByText("Anulado")).toBeInTheDocument()
  })

  it("renderiza el texto largo 'Anulado (no se envió a ARCA)' con verbose", () => {
    render(<FiscalDocumentBadge documentId="fd-1" initialStatus="voided" verbose />)
    expect(screen.getByText("Anulado (no se envió a ARCA)")).toBeInTheDocument()
  })

  it("NO abre canal de Realtime para un anulado (estado terminal)", () => {
    channelSpy.mockClear()
    render(<FiscalDocumentBadge documentId="fd-1" initialStatus="voided" />)
    expect(channelSpy).not.toHaveBeenCalled()
  })

  it("CONTROL POSITIVO: un pending_cae SÍ abre canal — si no, el test de arriba pasaría por accidente", () => {
    channelSpy.mockClear()
    render(<FiscalDocumentBadge documentId="fd-2" initialStatus="pending_cae" />)
    expect(channelSpy).toHaveBeenCalledTimes(1)
  })

  it("un anulado usa tokens semánticos (superficie neutra), no el rojo de rechazado", () => {
    const { container } = render(<FiscalDocumentBadge documentId="fd-1" initialStatus="voided" />)
    const badge = container.querySelector("[class*='bg-muted']")
    expect(badge).not.toBeNull()
    expect(container.innerHTML).not.toMatch(/bg-red-500/)
  })

  // Red team 2026-09-22 (n2): el read model del listado es fail-open para lo
  // desconocido (`as FiscalDocumentStatus` sobre un string del servidor) y el
  // badge hacía `STATUS_CONFIG[status]` sin fallback: un valor que este bundle
  // no conozca —el CHECK de fiscal_documents puede ganar uno antes de que el
  // frontend se despliegue— daba `undefined` y tiraba el render de la fila
  // ENTERA con un TypeError. Mostrar el estado mal es malo; no mostrar la venta
  // es peor.
  it("un status que el cliente no conoce no rompe el render: cae en 'Estado desconocido'", () => {
    const { container } = render(
      // @ts-expect-error — a propósito: simula un status que el servidor ya
      // emite y este bundle todavía no conoce.
      <FiscalDocumentBadge documentId="fd-4" initialStatus="cancelado_por_arca" />,
    )
    expect(screen.getByText("Estado desconocido")).toBeInTheDocument()
    expect(container.innerHTML).not.toMatch(/undefined/)
  })

  it("con verbose, el estado desconocido dice CUÁL era — para que se pueda diagnosticar", () => {
    render(
      // @ts-expect-error — ver arriba.
      <FiscalDocumentBadge documentId="fd-5" initialStatus="cancelado_por_arca" verbose />,
    )
    expect(screen.getByText("Estado desconocido (cancelado_por_arca)")).toBeInTheDocument()
  })

  it("no se confunde con rejected: 'Rechazado' sigue siendo su propio rótulo", () => {
    render(<FiscalDocumentBadge documentId="fd-3" initialStatus="rejected" verbose />)
    expect(screen.getByText("Rechazado por AFIP")).toBeInTheDocument()
    expect(screen.queryByText(/Anulado/)).toBeNull()
  })
})

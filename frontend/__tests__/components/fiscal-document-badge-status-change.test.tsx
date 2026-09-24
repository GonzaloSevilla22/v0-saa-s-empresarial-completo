/**
 * venta-editable-vs-promocion-legacy — el badge avisa cuando el relay cambia el
 * estado (pending_cae → authorized) por Realtime, para que el listado de
 * /ventas se refresque solo (texto lateral "Comprobante enviado a ARCA").
 *
 * El callback se guarda en una ref: si entrara en las deps del efecto, cada
 * render del listado (que pasa una arrow nueva) re-suscribiría el canal.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, act } from "@testing-library/react"

type Handler = (payload: { new?: Record<string, unknown> }) => void
const channelSpy = vi.fn()
const handlers: Handler[] = []

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    channel: (...args: unknown[]) => {
      channelSpy(...args)
      const chan = {
        on: (_e: string, _f: unknown, h: Handler) => { handlers.push(h); return chan },
        subscribe: () => chan,
      }
      return chan
    },
    removeChannel: vi.fn(),
  }),
}))

import { FiscalDocumentBadge } from "@/components/fiscal/FiscalDocumentBadge"

describe("FiscalDocumentBadge — onStatusChange", () => {
  beforeEach(() => { channelSpy.mockClear(); handlers.length = 0 })

  it("un UPDATE a authorized llama onStatusChange('authorized') UNA vez y el badge dice 'Autorizado por AFIP'", () => {
    const onStatusChange = vi.fn()
    render(<FiscalDocumentBadge documentId="fd-1" initialStatus="pending_cae" verbose onStatusChange={onStatusChange} />)
    expect(handlers).toHaveLength(1)

    act(() => { handlers[0]({ new: { status: "authorized" } }) })

    expect(onStatusChange).toHaveBeenCalledTimes(1)
    expect(onStatusChange).toHaveBeenCalledWith("authorized")
    expect(screen.getByText("Autorizado por AFIP")).toBeInTheDocument()
  })

  it("un UPDATE que NO cambia el status (p.ej. el lease del relay) no avisa", () => {
    const onStatusChange = vi.fn()
    render(<FiscalDocumentBadge documentId="fd-2" initialStatus="pending_cae" onStatusChange={onStatusChange} />)
    act(() => { handlers[0]({ new: { status: "pending_cae", attempts: 1 } }) })
    expect(onStatusChange).not.toHaveBeenCalled()
  })

  it("re-renderizar con un callback NUEVO no re-suscribe el canal, y el aviso llega al callback vigente", () => {
    const first = vi.fn()
    const second = vi.fn()
    const { rerender } = render(<FiscalDocumentBadge documentId="fd-3" initialStatus="pending_cae" onStatusChange={first} />)
    rerender(<FiscalDocumentBadge documentId="fd-3" initialStatus="pending_cae" onStatusChange={second} />)

    expect(channelSpy).toHaveBeenCalledTimes(1)

    act(() => { handlers[handlers.length - 1]({ new: { status: "rejected" } }) })
    expect(second).toHaveBeenCalledWith("rejected")
    expect(first).not.toHaveBeenCalled()
  })
})

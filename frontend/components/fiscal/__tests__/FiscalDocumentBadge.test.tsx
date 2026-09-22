/**
 * fiscal-emision-segura (M-4, red team 2026-09-22).
 *
 * Un comprobante CONGELADO (G4 — un FECAESolicitar salió y su resultado nunca
 * se confirmó) sigue reportando status='pending_cae' para siempre. Sin una
 * bandera propia, FiscalDocumentBadge lo muestra "En trámite" indefinidamente
 * y nadie sabe que necesita revisión manual en ARCA.
 *
 * Mock del canal de Realtime: mismo patrón que
 * __tests__/hooks/use-notifications.test.ts (channel/on/subscribe con el
 * callback capturado para simular un UPDATE en vivo).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { act, render, screen } from "@testing-library/react"

import { FiscalDocumentBadge } from "@/components/fiscal/FiscalDocumentBadge"

const channelOnMock = vi.fn()
const channelSubscribeMock = vi.fn()
const channelMock = vi.fn()
const removeChannelMock = vi.fn()

let realtimeCallback:
  | ((payload: { new: Record<string, unknown> }) => void)
  | null = null

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    channel: channelMock,
    removeChannel: removeChannelMock,
  }),
}))

describe("FiscalDocumentBadge", () => {
  beforeEach(() => {
    channelMock.mockReset()
    channelOnMock.mockReset()
    channelSubscribeMock.mockReset()
    removeChannelMock.mockReset()
    realtimeCallback = null

    channelOnMock.mockImplementation((_event, _config, cb) => {
      realtimeCallback = cb
      return { subscribe: channelSubscribeMock }
    })
    channelSubscribeMock.mockImplementation(() => ({ unsubscribe: vi.fn() }))
    channelMock.mockReturnValue({ on: channelOnMock })
  })

  it("muestra 'En trámite' por defecto para un pending_cae normal (no regresión)", () => {
    render(<FiscalDocumentBadge documentId="doc-1" initialStatus="pending_cae" />)

    expect(screen.getByText("En trámite")).toBeInTheDocument()
    expect(screen.queryByText("Congelado")).not.toBeInTheDocument()
  })

  it("muestra 'Congelado' cuando initialFrozen=true, aunque el status siga pending_cae", () => {
    render(
      <FiscalDocumentBadge documentId="doc-2" initialStatus="pending_cae" initialFrozen />,
    )

    expect(screen.getByText("Congelado")).toBeInTheDocument()
    expect(screen.queryByText("En trámite")).not.toBeInTheDocument()
  })

  it("verbose muestra el texto largo de congelado", () => {
    render(
      <FiscalDocumentBadge
        documentId="doc-3"
        initialStatus="pending_cae"
        initialFrozen
        verbose
      />,
    )

    expect(screen.getByText("Congelado — requiere revisión manual")).toBeInTheDocument()
  })

  it("un UPDATE de Realtime con cae_submit_unconfirmed_at pasa el badge a Congelado en vivo", () => {
    render(<FiscalDocumentBadge documentId="doc-4" initialStatus="pending_cae" />)

    expect(screen.getByText("En trámite")).toBeInTheDocument()

    act(() => {
      realtimeCallback?.({
        new: {
          status: "pending_cae",
          cae_submit_unconfirmed_at: "2026-09-22T12:00:00.000Z",
        },
      })
    })

    expect(screen.getByText("Congelado")).toBeInTheDocument()
  })

  it("un UPDATE de Realtime sin cae_submit_unconfirmed_at no congela (no regresión del camino feliz)", () => {
    render(<FiscalDocumentBadge documentId="doc-5" initialStatus="pending_cae" />)

    act(() => {
      realtimeCallback?.({ new: { status: "authorized" } })
    })

    expect(screen.getByText("Autorizado")).toBeInTheDocument()
    expect(screen.queryByText("Congelado")).not.toBeInTheDocument()
  })
})

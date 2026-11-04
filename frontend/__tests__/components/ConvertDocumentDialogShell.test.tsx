/**
 * remitos-compra (tanda B, 7.5, Regla de Tres) — `ConvertDocumentDialogShell`: la
 * cáscara compartida de los TRES diálogos que convierten un documento en una
 * operación (presupuesto → venta, remito de venta → venta, remito de compra →
 * compra).
 *
 * Qué fija (lo que antes estaba copiado en cada diálogo):
 *  - el cierre de la conversión: un candado SÍNCRONO contra el doble clic, la
 *    request en vuelo que impide cerrar, el aviso accionable en `role="alert"`
 *    SIN cerrar y el estado de éxito que no depende del documento;
 *  - la clave de idempotencia POR documento: se conserva al reintentar tras un
 *    fallo, se renueva tras `idempotency_key_conflict` y se resetea tras cada éxito;
 *  - la recarga del documento (`reload`) sólo cuando el error lo pide, y la de las
 *    sesiones de caja cuando la caja se cerró mientras se confirmaba;
 *  - el panel de documento ya no pendiente (`staleMessage`), que sólo deja Cerrar.
 *
 * Las reglas de DINERO (qué payload se manda, qué campos exige) NO viven acá: son
 * de cada diálogo y las cubren sus propios tests. Esta cáscara no sabe de ventas.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor, within, act } from "@testing-library/react"
import "@testing-library/jest-dom"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"

import { PythonApiError } from "@/lib/api/python-api-error"
import type { HumanizedOperationError } from "@/lib/operation-errors"
import { ConvertDocumentDialogShell } from "@/components/shared/ConvertDocumentDialogShell"

interface Result {
  id: string
  replayed: boolean
}

const RELOAD = { pattern: /doc_changed|doc_invalid_state/, queryKey: ["docs", "detail", "d-1"] as const }

let queryClient: QueryClient
let invalidateSpy: ReturnType<typeof vi.spyOn>

const onConfirm = vi.fn<(key: string) => Promise<Result>>()
const humanizeError = vi.fn<(source: string) => HumanizedOperationError>()
const fieldsSpy = vi.fn()

interface Overrides {
  scope?: string
  confirmDisabled?: boolean
  confirmDescribedBy?: string
  staleMessage?: string | null
  onOpenChange?: (open: boolean) => void
}

function Shell({ scope = "doc-convert:d-1", confirmDisabled = false, confirmDescribedBy, staleMessage = null, onOpenChange = vi.fn() }: Overrides) {
  return (
    <QueryClientProvider client={queryClient}>
      <ConvertDocumentDialogShell<Result>
        open
        onOpenChange={onOpenChange}
        title="Pasar a algo"
        idempotencyScope={scope}
        summary={<p>RESUMEN DEL DOCUMENTO</p>}
        renderFields={({ submitting }) => {
          fieldsSpy(submitting)
          return <input aria-label="Campo de cierre" disabled={submitting} />
        }}
        confirmLabel="Registrar cosa"
        confirmDisabled={confirmDisabled}
        confirmDescribedBy={confirmDescribedBy}
        onConfirm={onConfirm}
        renderSuccess={(result, close) => (
          <div>
            <h2>Cosa registrada {result.id}{result.replayed ? " (replay)" : ""}</h2>
            <button type="button" onClick={close}>Cerrar éxito</button>
          </div>
        )}
        humanizeError={humanizeError}
        reload={RELOAD}
        staleMessage={staleMessage}
      />
    </QueryClientProvider>
  )
}

function renderShell(overrides: Overrides = {}) {
  const onOpenChange = overrides.onOpenChange ?? vi.fn()
  const view = render(<Shell {...overrides} onOpenChange={onOpenChange} />)
  return { ...view, onOpenChange, rerenderWith: (next: Overrides) => view.rerender(<Shell {...next} onOpenChange={onOpenChange} />) }
}

const confirmButton = () => screen.getByRole("button", { name: /^registrar cosa$/i })

beforeEach(() => {
  vi.clearAllMocks()
  window.sessionStorage.clear()
  onConfirm.mockResolvedValue({ id: "r-1", replayed: false })
  humanizeError.mockImplementation((source) => ({ message: `humanizado: ${source}` }))
  queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  invalidateSpy = vi.spyOn(queryClient, "invalidateQueries")
})

describe("ConvertDocumentDialogShell — estructura", () => {
  it("muestra el título, el resumen, los campos de cierre y el botón de confirmar", () => {
    renderShell()
    const dialog = screen.getByRole("dialog")

    expect(within(dialog).getByText("Pasar a algo")).toBeInTheDocument()
    expect(within(dialog).getByText("RESUMEN DEL DOCUMENTO")).toBeInTheDocument()
    expect(within(dialog).getByLabelText("Campo de cierre")).toBeEnabled()
    expect(confirmButton()).toBeEnabled()
    expect(within(dialog).getByRole("button", { name: /^cancelar$/i })).toBeEnabled()
  })

  it("confirmDisabled deshabilita el botón, lo describe con confirmDescribedBy y el clic no convierte", () => {
    renderShell({ confirmDisabled: true, confirmDescribedBy: "motivo-id" })

    expect(confirmButton()).toBeDisabled()
    expect(confirmButton()).toHaveAttribute("aria-describedby", "motivo-id")
    fireEvent.click(confirmButton())
    expect(onConfirm).not.toHaveBeenCalled()
  })

  it("sin motivo de bloqueo, el botón no declara aria-describedby", () => {
    renderShell({ confirmDisabled: false, confirmDescribedBy: "motivo-id" })
    // confirmDescribedBy sólo describe un botón bloqueado: habilitado no apunta a nada.
    expect(confirmButton()).toBeEnabled()
    expect(confirmButton()).not.toHaveAttribute("aria-describedby")
  })
})

describe("ConvertDocumentDialogShell — la conversión y el éxito", () => {
  it("llama a onConfirm con la clave del documento y pasa al estado de éxito sin depender del documento", async () => {
    renderShell()
    fireEvent.click(confirmButton())

    await screen.findByRole("heading", { name: /cosa registrada r-1/i })
    expect(onConfirm).toHaveBeenCalledTimes(1)
    const key = onConfirm.mock.calls[0][0]
    expect(typeof key).toBe("string")
    expect(key.length).toBeGreaterThan(8)
    // El estado de éxito reemplaza al formulario completo.
    expect(screen.queryByLabelText("Campo de cierre")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /^registrar cosa$/i })).not.toBeInTheDocument()
  })

  it("el cierre del éxito cierra el diálogo", async () => {
    const { onOpenChange } = renderShell()
    fireEvent.click(confirmButton())
    await screen.findByRole("heading", { name: /cosa registrada/i })

    fireEvent.click(screen.getByRole("button", { name: /^cerrar éxito$/i }))
    expect(onOpenChange).toHaveBeenCalledWith(false)
  })

  it("el replay se entrega tal cual a renderSuccess", async () => {
    onConfirm.mockResolvedValue({ id: "r-9", replayed: true })
    renderShell()
    fireEvent.click(confirmButton())
    expect(await screen.findByRole("heading", { name: /cosa registrada r-9 \(replay\)/i })).toBeInTheDocument()
  })

  it("la clave se resetea tras el éxito: la próxima operación nace con otra", async () => {
    renderShell()
    fireEvent.click(confirmButton())
    await screen.findByRole("heading", { name: /cosa registrada/i })

    const used = onConfirm.mock.calls[0][0]
    expect(window.sessionStorage.getItem("idem:doc-convert:d-1")).not.toBe(used)
  })

  it("la clave es POR documento: A y B no comparten", async () => {
    const a = renderShell({ scope: "doc-convert:d-A" })
    fireEvent.click(confirmButton())
    await screen.findByRole("heading", { name: /cosa registrada/i })
    a.unmount()

    renderShell({ scope: "doc-convert:d-B" })
    fireEvent.click(confirmButton())
    await waitFor(() => expect(onConfirm).toHaveBeenCalledTimes(2))

    expect(onConfirm.mock.calls[1][0]).not.toBe(onConfirm.mock.calls[0][0])
  })
})

describe("ConvertDocumentDialogShell — request en vuelo y doble clic", () => {
  it("dos clics seguidos producen UNA sola request (candado síncrono)", async () => {
    let resolve!: (value: Result) => void
    onConfirm.mockReturnValue(new Promise<Result>((r) => { resolve = r }))
    renderShell()

    // Los dos clics caen en el MISMO tick, antes de que React vuelva a renderizar el botón
    // como deshabilitado: sólo el candado síncrono (ref) frena el segundo.
    const button = confirmButton()
    act(() => {
      button.click()
      button.click()
    })

    expect(onConfirm).toHaveBeenCalledTimes(1)
    await act(async () => {
      resolve({ id: "r-1", replayed: false })
    })
    await screen.findByRole("heading", { name: /cosa registrada/i })
    expect(onConfirm).toHaveBeenCalledTimes(1)
  })

  it("con la request en vuelo: 'Registrando…', campos deshabilitados, Cancelar deshabilitado y el cierre no pasa", async () => {
    let resolve!: (value: Result) => void
    onConfirm.mockReturnValue(new Promise<Result>((r) => { resolve = r }))
    const { onOpenChange } = renderShell()
    fireEvent.click(confirmButton())

    expect(await screen.findByRole("button", { name: /registrando/i })).toBeDisabled()
    expect(screen.getByLabelText("Campo de cierre")).toBeDisabled()
    expect(screen.getByRole("button", { name: /^cancelar$/i })).toBeDisabled()
    expect(fieldsSpy).toHaveBeenCalledWith(true)

    // Escape no cierra una conversión en vuelo: la respuesta tiene que verse.
    fireEvent.keyDown(screen.getByRole("dialog"), { key: "Escape" })
    expect(onOpenChange).not.toHaveBeenCalledWith(false)

    await act(async () => {
      resolve({ id: "r-1", replayed: false })
    })
    await screen.findByRole("heading", { name: /cosa registrada/i })
  })

  it("Cancelar cierra cuando no hay nada en vuelo", () => {
    const { onOpenChange } = renderShell()
    fireEvent.click(screen.getByRole("button", { name: /^cancelar$/i }))
    expect(onOpenChange).toHaveBeenCalledWith(false)
  })
})

describe("ConvertDocumentDialogShell — errores (el diálogo no se cierra)", () => {
  async function failWith(err: unknown) {
    onConfirm.mockRejectedValueOnce(err)
    const view = renderShell()
    fireEvent.click(confirmButton())
    const alert = await screen.findByRole("alert")
    return { alert, ...view }
  }

  it("muestra el mensaje humanizado en role=alert y deja el formulario abierto", async () => {
    const { alert, onOpenChange } = await failWith(new PythonApiError("payment_method_required", 400, { code: "payment_method_required" }))

    expect(alert).toHaveTextContent(/humanizado: payment_method_required/)
    expect(onOpenChange).not.toHaveBeenCalledWith(false)
    expect(screen.getByLabelText("Campo de cierre")).toBeEnabled()
    expect(confirmButton()).toBeEnabled()
  })

  it("entrega a humanizeError el code estable Y el texto del servidor, juntos (sin duplicar el code)", async () => {
    await failWith(new PythonApiError("Falta algo en el documento", 409, { code: "doc_changed" }))
    expect(humanizeError).toHaveBeenCalledWith("Falta algo en el documento doc_changed")

    humanizeError.mockClear()
    onConfirm.mockRejectedValueOnce(new PythonApiError("doc_changed: cambió", 409, { code: "doc_changed" }))
    fireEvent.click(confirmButton())
    await waitFor(() => expect(humanizeError).toHaveBeenCalledTimes(1))
    expect(humanizeError).toHaveBeenCalledWith("doc_changed: cambió")
  })

  it("un Error común aporta su mensaje; algo que no es un Error aporta texto vacío (no revienta)", async () => {
    await failWith(new Error("boom"))
    expect(humanizeError).toHaveBeenLastCalledWith("boom")

    humanizeError.mockClear()
    onConfirm.mockRejectedValueOnce("cadena suelta")
    fireEvent.click(confirmButton())
    await waitFor(() => expect(humanizeError).toHaveBeenCalledTimes(1))
    expect(humanizeError).toHaveBeenCalledWith("")
  })

  it("el enlace de acción del error se muestra y apunta adonde dice", async () => {
    humanizeError.mockReturnValue({ message: "Abrí la caja", action: { label: "Ir a caja", href: "/caja" } })
    const { alert } = await failWith(new PythonApiError("x", 409, {}))

    expect(within(alert).getByRole("link", { name: "Ir a caja" })).toHaveAttribute("href", "/caja")
  })

  it("el aviso de un intento se limpia al reintentar (también mientras el segundo intento está en vuelo)", async () => {
    await failWith(new PythonApiError("concurrent_update_retry", 409, {}))
    let resolve!: (value: Result) => void
    onConfirm.mockReturnValueOnce(new Promise<Result>((r) => { resolve = r }))
    fireEvent.click(confirmButton())

    // El segundo intento todavía no respondió: el aviso del primero ya no tiene que verse.
    await screen.findByRole("button", { name: /registrando/i })
    expect(screen.queryByRole("alert")).not.toBeInTheDocument()

    await act(async () => {
      resolve({ id: "r-1", replayed: false })
    })
    await screen.findByRole("heading", { name: /cosa registrada/i })
  })

  it("el reintento tras un fallo cualquiera conserva LA MISMA clave (un fallo revierte todo, incluida la clave)", async () => {
    await failWith(new PythonApiError("concurrent_update_retry", 409, { code: "concurrent_update_retry" }))
    fireEvent.click(confirmButton())
    await waitFor(() => expect(onConfirm).toHaveBeenCalledTimes(2))

    expect(onConfirm.mock.calls[1][0]).toBe(onConfirm.mock.calls[0][0])
  })

  it("idempotency_key_conflict: el reintento usa una clave NUEVA (si no, chocaría con el mismo conflicto)", async () => {
    await failWith(new PythonApiError("idempotency_key_conflict", 409, { code: "idempotency_key_conflict" }))
    fireEvent.click(confirmButton())
    await waitFor(() => expect(onConfirm).toHaveBeenCalledTimes(2))

    expect(onConfirm.mock.calls[1][0]).not.toBe(onConfirm.mock.calls[0][0])
  })
})

describe("ConvertDocumentDialogShell — recargas", () => {
  it("un error que coincide con reload.pattern recarga ESA consulta y no cierra", async () => {
    onConfirm.mockRejectedValueOnce(new PythonApiError("doc_changed", 409, { code: "doc_changed" }))
    const { onOpenChange } = renderShell()
    fireEvent.click(confirmButton())
    await screen.findByRole("alert")

    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["docs", "detail", "d-1"] })
    expect(onOpenChange).not.toHaveBeenCalledWith(false)
  })

  it("el segundo token del patrón también recarga", async () => {
    onConfirm.mockRejectedValueOnce(new PythonApiError("doc_invalid_state: estado actual converted", 409, { code: "doc_invalid_state" }))
    renderShell()
    fireEvent.click(confirmButton())
    await screen.findByRole("alert")

    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["docs", "detail", "d-1"] })
  })

  it("un error que no es de versión NO recarga el documento", async () => {
    onConfirm.mockRejectedValueOnce(new PythonApiError("payment_method_required", 400, { code: "payment_method_required" }))
    renderShell()
    fireEvent.click(confirmButton())
    await screen.findByRole("alert")

    expect(invalidateSpy).not.toHaveBeenCalledWith({ queryKey: ["docs", "detail", "d-1"] })
  })

  it.each(["cash_optin_requires_open_session", "cash_requires_session"])(
    "%s (la caja se cerró mientras se confirmaba): recarga las sesiones de caja",
    async (token) => {
      onConfirm.mockRejectedValueOnce(new PythonApiError(`${token}: la sesión de caja debe estar abierta`, 409, { code: token }))
      renderShell()
      fireEvent.click(confirmButton())
      await screen.findByRole("alert")

      expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["cashSessions"] })
    },
  )

  it("un error ajeno a la caja NO recarga las sesiones", async () => {
    onConfirm.mockRejectedValueOnce(new PythonApiError("concurrent_update_retry", 409, {}))
    renderShell()
    fireEvent.click(confirmButton())
    await screen.findByRole("alert")

    expect(invalidateSpy).not.toHaveBeenCalledWith({ queryKey: ["cashSessions"] })
  })
})

describe("ConvertDocumentDialogShell — el documento ya no está pendiente", () => {
  it("con staleMessage: lo avisa en role=status y sólo deja Cerrar (sin formulario ni confirmar)", () => {
    const { onOpenChange } = renderShell({ staleMessage: "El documento ya fue convertido: no hay nada para registrar." })
    const dialog = screen.getByRole("dialog")

    expect(within(dialog).getByRole("status")).toHaveTextContent(/ya fue convertido/i)
    expect(within(dialog).queryByLabelText("Campo de cierre")).not.toBeInTheDocument()
    expect(within(dialog).queryByRole("button", { name: /^registrar cosa$/i })).not.toBeInTheDocument()
    expect(within(dialog).queryByText("RESUMEN DEL DOCUMENTO")).not.toBeInTheDocument()

    fireEvent.click(within(dialog).getByRole("button", { name: /^cerrar$/i }))
    expect(onOpenChange).toHaveBeenCalledWith(false)
  })

  it("sin staleMessage (null) sigue mostrando el formulario completo", () => {
    renderShell({ staleMessage: null })
    expect(screen.getByLabelText("Campo de cierre")).toBeInTheDocument()
    expect(screen.queryByRole("status")).not.toBeInTheDocument()
  })

  it("el éxito manda sobre el aviso: tras convertir, aunque el documento ya figure no pendiente, se sigue viendo el recibo", async () => {
    const view = renderShell()
    fireEvent.click(confirmButton())
    await screen.findByRole("heading", { name: /cosa registrada/i })

    view.rerenderWith({ staleMessage: "El documento ya fue convertido: no hay nada para registrar." })

    expect(screen.getByRole("heading", { name: /cosa registrada/i })).toBeInTheDocument()
    expect(screen.queryByRole("status")).not.toBeInTheDocument()
  })
})

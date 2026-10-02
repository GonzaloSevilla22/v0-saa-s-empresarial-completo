/**
 * presupuestos-modulo (D9, tarea 5.1) — `DocumentShareMenu`.
 *
 * Menú único de "Ver / Descargar / WhatsApp" para un documento comercial en
 * PDF. Lo que fija este archivo:
 *   - "Ver" abre la pestaña DENTRO del gesto (Safari iOS) y no marca enviado;
 *   - el PDF se precarga al abrir el menú y el share nativo se invoca en el
 *     mismo toque, con el blob listo; sin blob, "Preparando…";
 *   - "Descargar" y WhatsApp avisan `onShared`; un share cancelado, no;
 *   - sin `onShared` (rol sin permiso) todo funciona igual;
 *   - un 401 no muestra toast de error.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

const mocks = vi.hoisted(() => ({
  downloadBlob: vi.fn(),
  sharePdf: vi.fn(),
  openWhatsAppText: vi.fn(),
  toastInfo: vi.fn(),
  toastError: vi.fn(),
  toastSuccess: vi.fn(),
}))

vi.mock("@/lib/document-share", () => ({
  downloadBlob: mocks.downloadBlob,
  sharePdf: mocks.sharePdf,
  openWhatsAppText: mocks.openWhatsAppText,
}))
vi.mock("sonner", () => ({
  toast: { info: mocks.toastInfo, error: mocks.toastError, success: mocks.toastSuccess },
}))

import { DocumentShareMenu } from "@/components/shared/DocumentShareMenu"
import { DocumentPdfError } from "@/lib/api/document-pdf"

const FILE_NAME = "presupuesto-P-00000012.pdf"
const SHARE_TEXT = "Hola Ana, te envío el presupuesto P-00000012 por $ 12.345."
const SHARE_TITLE = "Presupuesto P-00000012"

interface Deferred<T> {
  promise: Promise<T>
  resolve: (value: T) => void
  reject: (reason: unknown) => void
}

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void
  let reject!: (reason: unknown) => void
  const promise = new Promise<T>((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, resolve, reject }
}

function pdfBlob(): Blob {
  return new Blob(["%PDF-1.4"], { type: "application/pdf" })
}

type FetchPdf = (disposition: "inline" | "attachment") => Promise<Blob | null>

function renderMenu(opts: {
  fetchPdf?: FetchPdf
  onShared?: () => void
  clientPhone?: string | null
} = {}) {
  const fetchPdf = opts.fetchPdf ?? vi.fn<FetchPdf>().mockResolvedValue(pdfBlob())
  const utils = render(
    <DocumentShareMenu
      fetchPdf={fetchPdf}
      fileName={FILE_NAME}
      shareText={SHARE_TEXT}
      shareTitle={SHARE_TITLE}
      clientPhone={opts.clientPhone === undefined ? "2615551234" : opts.clientPhone}
      onShared={opts.onShared}
    />,
  )
  return { fetchPdf, ...utils }
}

async function openMenu(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole("button", { name: /compartir/i }))
}

/** El menú ya abierto y con el PDF precargado: el ítem de WhatsApp listo para tocar. */
async function openMenuWithBlobReady(user: ReturnType<typeof userEvent.setup>, fetchPdf: FetchPdf) {
  await openMenu(user)
  await waitFor(() => expect(fetchPdf).toHaveBeenCalledTimes(1))
  return screen.findByRole("menuitem", { name: /whatsapp/i })
}

describe("DocumentShareMenu", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mocks.sharePdf.mockResolvedValue("shared")
    mocks.openWhatsAppText.mockReturnValue(true)
    vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:mock-pdf")
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {})
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  describe("precarga", () => {
    it("no pide el PDF hasta que se abre el menú, y lo pide una vez al abrirlo (attachment)", async () => {
      const user = userEvent.setup()
      const fetchPdf = vi.fn<FetchPdf>().mockResolvedValue(pdfBlob())
      renderMenu({ fetchPdf })

      expect(fetchPdf).not.toHaveBeenCalled()
      await openMenu(user)

      await waitFor(() => expect(fetchPdf).toHaveBeenCalledTimes(1))
      expect(fetchPdf).toHaveBeenCalledWith("attachment")
    })
  })

  describe("Ver / imprimir", () => {
    it("abre la pestaña dentro del gesto, antes de que llegue el PDF, y no llama a onShared", async () => {
      const user = userEvent.setup()
      const inline = deferred<Blob | null>()
      const fetchPdf = vi.fn<FetchPdf>((disposition) =>
        disposition === "inline" ? inline.promise : new Promise<Blob | null>(() => {}),
      )
      const onShared = vi.fn()
      const tab = { location: { href: "" }, close: vi.fn() }
      const openSpy = vi.spyOn(window, "open").mockReturnValue(tab as unknown as Window)
      renderMenu({ fetchPdf, onShared })

      await openMenu(user)
      await user.click(await screen.findByRole("menuitem", { name: /ver/i }))

      // La pestaña ya está abierta aunque el PDF todavía no llegó.
      expect(openSpy).toHaveBeenCalledWith("", "_blank")
      expect(tab.location.href).toBe("")

      inline.resolve(pdfBlob())
      await waitFor(() => expect(tab.location.href).toBe("blob:mock-pdf"))
      expect(onShared).not.toHaveBeenCalled()
      expect(mocks.downloadBlob).not.toHaveBeenCalled()
    })

    it("si el navegador bloquea la pestaña, descarga el PDF (sin marcar enviado)", async () => {
      const user = userEvent.setup()
      const onShared = vi.fn()
      vi.spyOn(window, "open").mockReturnValue(null)
      const { fetchPdf } = renderMenu({ onShared })

      await openMenu(user)
      await waitFor(() => expect(fetchPdf).toHaveBeenCalled())
      await user.click(await screen.findByRole("menuitem", { name: /ver/i }))

      await waitFor(() => expect(mocks.downloadBlob).toHaveBeenCalledTimes(1))
      expect(mocks.downloadBlob.mock.calls[0][1]).toBe(FILE_NAME)
      expect(onShared).not.toHaveBeenCalled()
    })

    it("con la sesión vencida (null) cierra la pestaña y no muestra ningún toast de error", async () => {
      const user = userEvent.setup()
      const tab = { location: { href: "" }, close: vi.fn() }
      vi.spyOn(window, "open").mockReturnValue(tab as unknown as Window)
      // El precargado y el "inline" devuelven null: el 401 ya navegó al login.
      const fetchPdf = vi.fn<FetchPdf>().mockResolvedValue(null)
      renderMenu({ fetchPdf })

      await openMenu(user)
      await user.click(await screen.findByRole("menuitem", { name: /ver/i }))

      await waitFor(() => expect(tab.close).toHaveBeenCalled())
      expect(mocks.toastError).not.toHaveBeenCalled()
    })

    it("ante un error del servidor cierra la pestaña y avisa con el mensaje del backend", async () => {
      const user = userEvent.setup()
      const tab = { location: { href: "" }, close: vi.fn() }
      vi.spyOn(window, "open").mockReturnValue(tab as unknown as Window)
      const fetchPdf = vi.fn<FetchPdf>((disposition) =>
        disposition === "inline"
          ? Promise.reject(new DocumentPdfError("quote_not_found", "No encontramos el presupuesto.", 404))
          : new Promise<Blob | null>(() => {}),
      )
      renderMenu({ fetchPdf })

      await openMenu(user)
      await user.click(await screen.findByRole("menuitem", { name: /ver/i }))

      await waitFor(() => expect(tab.close).toHaveBeenCalled())
      expect(mocks.toastError).toHaveBeenCalledWith("No encontramos el presupuesto.")
    })
  })

  describe("Descargar PDF", () => {
    it("descarga el PDF precargado con el nombre del archivo y llama a onShared", async () => {
      const user = userEvent.setup()
      const onShared = vi.fn()
      const { fetchPdf } = renderMenu({ onShared })

      await openMenu(user)
      await waitFor(() => expect(fetchPdf).toHaveBeenCalledTimes(1))
      await user.click(await screen.findByRole("menuitem", { name: /descargar/i }))

      await waitFor(() => expect(mocks.downloadBlob).toHaveBeenCalledTimes(1))
      expect(mocks.downloadBlob.mock.calls[0][0]).toBeInstanceOf(Blob)
      expect(mocks.downloadBlob.mock.calls[0][1]).toBe(FILE_NAME)
      expect(onShared).toHaveBeenCalledTimes(1)
    })

    it("sin onShared (rol sin permiso) la descarga funciona igual", async () => {
      const user = userEvent.setup()
      const { fetchPdf } = renderMenu({ onShared: undefined })

      await openMenu(user)
      await waitFor(() => expect(fetchPdf).toHaveBeenCalledTimes(1))
      await user.click(await screen.findByRole("menuitem", { name: /descargar/i }))

      await waitFor(() => expect(mocks.downloadBlob).toHaveBeenCalledTimes(1))
    })

    it("si el PDF todavía no llegó, lo pide y descarga igual (sin quedarse sin acción)", async () => {
      const user = userEvent.setup()
      const onShared = vi.fn()
      const slow = deferred<Blob | null>()
      const fetchPdf = vi
        .fn<FetchPdf>()
        .mockReturnValueOnce(slow.promise) // la precarga, aún colgada
        .mockResolvedValue(pdfBlob()) // el pedido propio de la descarga
      renderMenu({ fetchPdf, onShared })

      await openMenu(user)
      await user.click(await screen.findByRole("menuitem", { name: /descargar/i }))

      await waitFor(() => expect(mocks.downloadBlob).toHaveBeenCalledTimes(1))
      expect(onShared).toHaveBeenCalledTimes(1)
    })

    it("con la sesión vencida (null) no descarga, no marca enviado y no muestra toast", async () => {
      const user = userEvent.setup()
      const onShared = vi.fn()
      const fetchPdf = vi.fn<FetchPdf>().mockResolvedValue(null)
      renderMenu({ fetchPdf, onShared })

      await openMenu(user)
      await waitFor(() => expect(fetchPdf).toHaveBeenCalled())
      await user.click(await screen.findByRole("menuitem", { name: /descargar/i }))

      await waitFor(() => expect(fetchPdf.mock.calls.length).toBeGreaterThanOrEqual(2))
      expect(mocks.downloadBlob).not.toHaveBeenCalled()
      expect(onShared).not.toHaveBeenCalled()
      expect(mocks.toastError).not.toHaveBeenCalled()
    })
  })

  describe("Enviar por WhatsApp", () => {
    it("con el blob listo comparte el File por el share nativo en el mismo toque, sin pedir otro PDF", async () => {
      const user = userEvent.setup()
      const onShared = vi.fn()
      const fetchPdf = vi.fn<FetchPdf>().mockResolvedValue(pdfBlob())
      renderMenu({ fetchPdf, onShared })

      const item = await openMenuWithBlobReady(user, fetchPdf)
      await user.click(item)

      await waitFor(() => expect(mocks.sharePdf).toHaveBeenCalledTimes(1))
      const [file, text, title] = mocks.sharePdf.mock.calls[0] as [File, string, string]
      expect(file).toBeInstanceOf(File)
      expect(file.name).toBe(FILE_NAME)
      expect(file.type).toBe("application/pdf")
      expect(text).toBe(SHARE_TEXT)
      expect(title).toBe(SHARE_TITLE)
      // El PDF ya estaba: el toque no esperó ningún fetch nuevo.
      expect(fetchPdf).toHaveBeenCalledTimes(1)
      await waitFor(() => expect(onShared).toHaveBeenCalledTimes(1))
      expect(mocks.downloadBlob).not.toHaveBeenCalled()
      expect(mocks.openWhatsAppText).not.toHaveBeenCalled()
    })

    it("sin blob todavía muestra 'Preparando…', no comparte y deja el menú abierto para un segundo toque", async () => {
      const user = userEvent.setup()
      const onShared = vi.fn()
      const preload = deferred<Blob | null>()
      const fetchPdf = vi.fn<FetchPdf>().mockReturnValue(preload.promise)
      renderMenu({ fetchPdf, onShared })

      await openMenu(user)
      const preparing = await screen.findByRole("menuitem", { name: /preparando/i })
      await user.click(preparing)

      expect(mocks.sharePdf).not.toHaveBeenCalled()
      expect(onShared).not.toHaveBeenCalled()
      // El menú sigue abierto: el segundo toque es posible.
      expect(screen.getByRole("menu")).toBeInTheDocument()

      preload.resolve(pdfBlob())
      const ready = await screen.findByRole("menuitem", { name: /whatsapp/i })
      await user.click(ready)

      await waitFor(() => expect(mocks.sharePdf).toHaveBeenCalledTimes(1))
      await waitFor(() => expect(onShared).toHaveBeenCalledTimes(1))
    })

    it("un share cancelado por el usuario NO llama a onShared ni cae al fallback", async () => {
      const user = userEvent.setup()
      const onShared = vi.fn()
      mocks.sharePdf.mockResolvedValue("cancelled")
      const fetchPdf = vi.fn<FetchPdf>().mockResolvedValue(pdfBlob())
      renderMenu({ fetchPdf, onShared })

      await user.click(await openMenuWithBlobReady(user, fetchPdf))

      await waitFor(() => expect(mocks.sharePdf).toHaveBeenCalledTimes(1))
      expect(onShared).not.toHaveBeenCalled()
      expect(mocks.downloadBlob).not.toHaveBeenCalled()
      expect(mocks.openWhatsAppText).not.toHaveBeenCalled()
    })

    it("sin share de archivos, con teléfono: descarga el PDF, abre wa.me al número y marca enviado", async () => {
      const user = userEvent.setup()
      const onShared = vi.fn()
      mocks.sharePdf.mockResolvedValue("unsupported")
      const fetchPdf = vi.fn<FetchPdf>().mockResolvedValue(pdfBlob())
      renderMenu({ fetchPdf, onShared, clientPhone: "2615551234" })

      await user.click(await openMenuWithBlobReady(user, fetchPdf))

      await waitFor(() => expect(mocks.downloadBlob).toHaveBeenCalledTimes(1))
      expect(mocks.downloadBlob.mock.calls[0][1]).toBe(FILE_NAME)
      expect(mocks.openWhatsAppText).toHaveBeenCalledWith("2615551234", SHARE_TEXT)
      expect(mocks.toastInfo).toHaveBeenCalledWith(expect.stringMatching(/adjuntalo en el chat/i))
      expect(mocks.toastInfo).not.toHaveBeenCalledWith(expect.stringMatching(/no hay número/i), expect.anything())
      expect(onShared).toHaveBeenCalledTimes(1)
    })

    it("sin share y sin teléfono válido: abre wa.me/?text= (selector de contacto) con el aviso", async () => {
      const user = userEvent.setup()
      const onShared = vi.fn()
      mocks.sharePdf.mockResolvedValue("unsupported")
      mocks.openWhatsAppText.mockReturnValue(false)
      const fetchPdf = vi.fn<FetchPdf>().mockResolvedValue(pdfBlob())
      renderMenu({ fetchPdf, onShared, clientPhone: null })

      await user.click(await openMenuWithBlobReady(user, fetchPdf))

      await waitFor(() => expect(mocks.openWhatsAppText).toHaveBeenCalledWith(null, SHARE_TEXT))
      expect(mocks.toastInfo).toHaveBeenCalledWith(
        expect.stringMatching(/no hay número de whatsapp registrado/i),
        expect.anything(),
      )
      // El PDF se descargó igual: hay algo que adjuntar en el chat.
      expect(mocks.downloadBlob).toHaveBeenCalledTimes(1)
      expect(onShared).toHaveBeenCalledTimes(1)
    })

    it("un 401 en la precarga no muestra toast de error y WhatsApp no hace nada", async () => {
      const user = userEvent.setup()
      const onShared = vi.fn()
      const fetchPdf = vi.fn<FetchPdf>().mockResolvedValue(null)
      renderMenu({ fetchPdf, onShared })

      await openMenu(user)
      await waitFor(() => expect(fetchPdf).toHaveBeenCalledTimes(1))

      expect(mocks.toastError).not.toHaveBeenCalled()
      expect(mocks.sharePdf).not.toHaveBeenCalled()
      expect(onShared).not.toHaveBeenCalled()
    })

    it("un error de precarga distinto de 401 avisa con el mensaje del backend", async () => {
      const user = userEvent.setup()
      const fetchPdf = vi
        .fn<FetchPdf>()
        .mockRejectedValue(new DocumentPdfError("quote_not_found", "No encontramos el presupuesto.", 404))
      renderMenu({ fetchPdf })

      await openMenu(user)

      await waitFor(() => expect(mocks.toastError).toHaveBeenCalledWith("No encontramos el presupuesto."))
    })
  })
})

/**
 * documentos-marca-empresa (task 11.2) — `DocumentLogoUpload`: subir, ver y quitar el logo
 * de la cuenta.
 *
 *  - sólo PNG/JPEG/WebP de hasta 2 MB (chequeo previo con el mensaje; el servidor revalida
 *    todo por contenido);
 *  - muestra el logo NORMALIZADO que devolvió el servidor (no el archivo elegido);
 *  - "Quitar logo" pide confirmación;
 *  - mensajes en castellano para 413/415/422/403;
 *  - sin permiso (no es owner/admin), sólo lectura: sin controles de subida.
 */
import React from "react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

const mocks = vi.hoisted(() => ({
  upload: vi.fn(),
  remove: vi.fn(),
  uploadPending: { value: false },
  removePending: { value: false },
  toastError: vi.fn(),
  toastSuccess: vi.fn(),
}))

vi.mock("sonner", () => ({ toast: { error: mocks.toastError, success: mocks.toastSuccess } }))
vi.mock("@/hooks/data/use-document-branding", () => ({
  useUploadDocumentLogo: () => ({ mutateAsync: mocks.upload, isPending: mocks.uploadPending.value }),
  useDeleteDocumentLogo: () => ({ mutateAsync: mocks.remove, isPending: mocks.removePending.value }),
}))

import { DocumentLogoUpload } from "@/components/settings/DocumentLogoUpload"
import { DocumentLogoError, LOGO_MAX_UPLOAD_BYTES } from "@/lib/api/document-logo"
import { LOGO_SHA, PNG_DATA_URI } from "../../helpers/branding-fixtures"

const LOGO = { sha256: LOGO_SHA, mime: "image/png", width: 1000, height: 250 }
const png = (size = 10, name = "logo.png") => new File([new Uint8Array(size)], name, { type: "image/png" })
const fileInput = () => document.querySelector('input[type="file"]') as HTMLInputElement

beforeEach(() => {
  vi.clearAllMocks()
  mocks.uploadPending.value = false
  mocks.removePending.value = false
  mocks.upload.mockResolvedValue(LOGO)
  mocks.remove.mockResolvedValue(undefined)
})

describe("DocumentLogoUpload — edición (owner/admin)", () => {
  it("el selector de archivos acepta sólo PNG, JPEG y WebP", () => {
    render(<DocumentLogoUpload logo={null} dataUri={undefined} canEdit />)
    expect(fileInput()).toHaveAttribute("accept", "image/png,image/jpeg,image/webp")
  })

  it("sin logo ofrece «Subir logo» y explica los límites", () => {
    render(<DocumentLogoUpload logo={null} dataUri={undefined} canEdit />)
    expect(screen.getByRole("button", { name: /subir logo/i })).toBeInTheDocument()
    expect(screen.getByText(/PNG, JPEG o WebP/)).toBeInTheDocument()
    expect(screen.getByText(/2 MB/)).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /quitar logo/i })).toBeNull()
  })

  it("con logo muestra la imagen que devolvió el servidor y ofrece «Cambiar» y «Quitar»", () => {
    render(<DocumentLogoUpload logo={LOGO} dataUri={PNG_DATA_URI} canEdit />)
    expect(screen.getByAltText("Logo de la empresa")).toHaveAttribute("src", PNG_DATA_URI)
    expect(screen.getByRole("button", { name: /cambiar logo/i })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /quitar logo/i })).toBeInTheDocument()
    expect(screen.getByText(/1000 × 250/)).toBeInTheDocument()
  })

  it("sube el archivo elegido y avisa", async () => {
    render(<DocumentLogoUpload logo={null} dataUri={undefined} canEdit />)
    const file = png()

    fireEvent.change(fileInput(), { target: { files: [file] } })

    await waitFor(() => expect(mocks.upload).toHaveBeenCalledWith(file))
    await waitFor(() => expect(mocks.toastSuccess).toHaveBeenCalledWith(expect.stringMatching(/logo/i)))
  })

  it.each([
    ["un SVG", new File(["<svg/>"], "logo.svg", { type: "image/svg+xml" }), /PNG, JPEG o WebP/],
    ["un GIF", new File([new Uint8Array(5)], "logo.gif", { type: "image/gif" }), /PNG, JPEG o WebP/],
    ["un archivo de más de 2 MB", png(LOGO_MAX_UPLOAD_BYTES + 1), /2 MB/],
  ])("rechaza %s ANTES de subir, con su mensaje", async (_name, file, message) => {
    render(<DocumentLogoUpload logo={null} dataUri={undefined} canEdit />)

    fireEvent.change(fileInput(), { target: { files: [file] } })

    await waitFor(() => expect(mocks.toastError).toHaveBeenCalledWith(expect.stringMatching(message)))
    expect(mocks.upload).not.toHaveBeenCalled()
  })

  it.each([
    ["branding_logo_too_large", 413, /2 MB/],
    ["branding_logo_unsupported_type", 415, /PNG, JPEG o WebP/],
    ["branding_logo_invalid", 422, /dañada|no se pudo leer/i],
    ["branding_logo_too_heavy", 422, /pesa demasiado/i],
    ["http_403", 403, /dueño o un administrador/i],
  ])("un rechazo del servidor (%s) se explica en castellano", async (code, status, message) => {
    mocks.upload.mockRejectedValue(new DocumentLogoError(code, "técnico", status))
    render(<DocumentLogoUpload logo={null} dataUri={undefined} canEdit />)

    fireEvent.change(fileInput(), { target: { files: [png()] } })

    await waitFor(() => expect(mocks.toastError).toHaveBeenCalledWith(expect.stringMatching(message)))
    expect(mocks.toastSuccess).not.toHaveBeenCalled()
  })

  it("un error inesperado muestra un mensaje genérico, nunca el texto técnico", async () => {
    mocks.upload.mockRejectedValue(new Error("Failed to fetch"))
    render(<DocumentLogoUpload logo={null} dataUri={undefined} canEdit />)

    fireEvent.change(fileInput(), { target: { files: [png()] } })

    await waitFor(() => expect(mocks.toastError).toHaveBeenCalledWith(expect.stringMatching(/No se pudo subir el logo/)))
    expect(mocks.toastError).not.toHaveBeenCalledWith(expect.stringMatching(/Failed to fetch/))
  })

  it.each([
    ["una subida exitosa", () => mocks.upload.mockResolvedValue(LOGO)],
    ["una subida rechazada", () => mocks.upload.mockRejectedValue(new Error("boom"))],
  ])("después de %s el selector se limpia (se puede elegir el mismo archivo de nuevo)", async (_name, arrange) => {
    arrange()
    render(<DocumentLogoUpload logo={null} dataUri={undefined} canEdit />)
    // jsdom no deja asignar `value` a un <input type=file> salvo con "", así que se espía el setter.
    const clears: string[] = []
    Object.defineProperty(fileInput(), "value", { configurable: true, get: () => "", set: (v: string) => clears.push(v) })

    fireEvent.change(fileInput(), { target: { files: [png()] } })

    await waitFor(() => expect(mocks.upload).toHaveBeenCalled())
    await waitFor(() => expect(clears).toEqual([""]))
  })

  it("un archivo rechazado antes de subir también deja el selector limpio", async () => {
    render(<DocumentLogoUpload logo={null} dataUri={undefined} canEdit />)
    const clears: string[] = []
    Object.defineProperty(fileInput(), "value", { configurable: true, get: () => "", set: (v: string) => clears.push(v) })

    fireEvent.change(fileInput(), { target: { files: [new File(["<svg/>"], "logo.svg", { type: "image/svg+xml" })] } })

    await waitFor(() => expect(mocks.toastError).toHaveBeenCalled())
    expect(clears).toEqual([""])
  })

  it("mientras sube, los controles quedan deshabilitados", () => {
    mocks.uploadPending.value = true
    render(<DocumentLogoUpload logo={LOGO} dataUri={PNG_DATA_URI} canEdit />)
    expect(screen.getByRole("button", { name: /cambiar logo|subiendo/i })).toBeDisabled()
    expect(screen.getByRole("button", { name: /quitar logo/i })).toBeDisabled()
  })

  describe("quitar el logo", () => {
    it("avisa que todos los papeles, la factura incluida, salen sin logo hasta que se suba otro", async () => {
      const user = userEvent.setup()
      render(<DocumentLogoUpload logo={LOGO} dataUri={PNG_DATA_URI} canEdit />)

      await user.click(screen.getByRole("button", { name: /quitar logo/i }))
      const dialog = await screen.findByRole("alertdialog")

      expect(dialog).toHaveTextContent(/comprobantes, presupuestos, remitos y facturas van a salir sin logo/i)
    })

    it("pide confirmación y, al confirmar, lo quita", async () => {
      const user = userEvent.setup()
      render(<DocumentLogoUpload logo={LOGO} dataUri={PNG_DATA_URI} canEdit />)

      await user.click(screen.getByRole("button", { name: /quitar logo/i }))
      const dialog = await screen.findByRole("alertdialog")
      expect(mocks.remove).not.toHaveBeenCalled()
      await user.click(within(dialog).getByRole("button", { name: /^quitar$/i }))

      await waitFor(() => expect(mocks.remove).toHaveBeenCalledTimes(1))
      expect(mocks.toastSuccess).toHaveBeenCalled()
    })

    it("si se cancela, no lo quita", async () => {
      const user = userEvent.setup()
      render(<DocumentLogoUpload logo={LOGO} dataUri={PNG_DATA_URI} canEdit />)

      await user.click(screen.getByRole("button", { name: /quitar logo/i }))
      await user.click(within(await screen.findByRole("alertdialog")).getByRole("button", { name: /cancelar/i }))

      expect(mocks.remove).not.toHaveBeenCalled()
    })

    it("un error al quitar se avisa", async () => {
      mocks.remove.mockRejectedValue(new DocumentLogoError("http_403", "x", 403))
      const user = userEvent.setup()
      render(<DocumentLogoUpload logo={LOGO} dataUri={PNG_DATA_URI} canEdit />)

      await user.click(screen.getByRole("button", { name: /quitar logo/i }))
      await user.click(within(await screen.findByRole("alertdialog")).getByRole("button", { name: /^quitar$/i }))

      await waitFor(() => expect(mocks.toastError).toHaveBeenCalled())
    })
  })
})

describe("DocumentLogoUpload — sólo lectura", () => {
  it("sin permiso no hay controles de subida ni de quitar, pero se ve el logo", () => {
    render(<DocumentLogoUpload logo={LOGO} dataUri={PNG_DATA_URI} canEdit={false} />)
    expect(screen.getByAltText("Logo de la empresa")).toBeInTheDocument()
    expect(screen.queryByRole("button")).toBeNull()
    expect(fileInput()).toBeNull()
  })

  it("sin logo y sin permiso lo dice", () => {
    render(<DocumentLogoUpload logo={null} dataUri={undefined} canEdit={false} />)
    expect(screen.getByText(/todavía no hay logo/i)).toBeInTheDocument()
    expect(fileInput()).toBeNull()
  })
})

describe("DocumentLogoUpload — seguridad de la imagen", () => {
  it("un data: inválido no se renderiza como imagen", () => {
    render(<DocumentLogoUpload logo={LOGO} dataUri={"https://evil.example/x.png"} canEdit />)
    expect(screen.queryByAltText("Logo de la empresa")).toBeNull()
  })
})

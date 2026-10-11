/**
 * documentos-marca-empresa (task 9.3) — transportes BINARIOS del logo:
 * `uploadDocumentLogo` (PUT con el cuerpo crudo de la imagen, sin multipart) y
 * `fetchDocumentLogoDataUri` (GET → `data:` URI validado). Mismo idioma que
 * `fetchDocumentPdf`: sesión por `getAuthHeaders`, 401 con `redirectedOnUnauthorized`
 * y errores RFC 7807 con su `code` estable.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

const { redirectedMock } = vi.hoisted(() => ({ redirectedMock: vi.fn() }))

vi.mock("@/lib/api/auth-headers", () => ({
  getAuthHeaders: vi.fn(async (extra?: Record<string, string>) => ({
    ...(extra ?? {}),
    Authorization: "Bearer tok-1",
  })),
  tokenFromHeaders: (h: Record<string, string>) => h.Authorization?.slice(7) ?? null,
  redirectedOnUnauthorized: redirectedMock,
}))

import {
  DocumentLogoError,
  fetchDocumentLogoDataUri,
  logoErrorMessage,
  uploadDocumentLogo,
  LOGO_MAX_UPLOAD_BYTES,
  validateLogoFile,
} from "@/lib/api/document-logo"

const DESCRIPTOR = { sha256: "a".repeat(64), mime: "image/png", width: 1000, height: 250 }

function json(status: number, body: unknown, type = "application/json"): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": type } })
}

const fetchMock = vi.fn()

beforeEach(() => {
  vi.stubEnv("NEXT_PUBLIC_BACKEND_URL", "http://api.test")
  vi.stubGlobal("fetch", fetchMock)
  fetchMock.mockReset()
  redirectedMock.mockReset()
  redirectedMock.mockResolvedValue(false)
})
afterEach(() => {
  vi.unstubAllEnvs()
  vi.unstubAllGlobals()
})

describe("uploadDocumentLogo", () => {
  const file = new File([new Uint8Array([1, 2, 3])], "logo.png", { type: "image/png" })

  it("PUT con el cuerpo binario crudo, el tipo del archivo y la sesión", async () => {
    fetchMock.mockResolvedValue(json(200, { logo: DESCRIPTOR }))

    const logo = await uploadDocumentLogo(file)

    expect(logo).toEqual(DESCRIPTOR)
    const [url, init] = fetchMock.mock.calls[0]
    expect(url).toBe("http://api.test/document-branding/logo")
    expect(init.method).toBe("PUT")
    expect(init.body).toBe(file)                                   // el Blob tal cual: sin FormData
    expect(init.headers).toEqual({ "Content-Type": "image/png", Authorization: "Bearer tok-1" })
  })

  it("un archivo sin tipo viaja como application/octet-stream (el servidor reconoce por contenido)", async () => {
    fetchMock.mockResolvedValue(json(200, { logo: DESCRIPTOR }))
    await uploadDocumentLogo(new File([new Uint8Array([1])], "logo"))
    expect(fetchMock.mock.calls[0][1].headers["Content-Type"]).toBe("application/octet-stream")
  })

  it("un 401 que ya navegó al login devuelve null", async () => {
    fetchMock.mockResolvedValue(new Response("", { status: 401 }))
    redirectedMock.mockResolvedValue(true)
    expect(await uploadDocumentLogo(file)).toBeNull()
  })

  it.each([
    [413, "branding_logo_too_large"],
    [415, "branding_logo_unsupported_type"],
    [422, "branding_logo_invalid"],
    [422, "branding_logo_too_heavy"],
  ])("un %i (%s) lanza DocumentLogoError con su code", async (status, code) => {
    fetchMock.mockResolvedValue(json(status, { code, detail: "x" }, "application/problem+json"))
    await expect(uploadDocumentLogo(file)).rejects.toMatchObject({ name: "DocumentLogoError", code, status })
  })

  it("un 403 se reconoce (sólo owner/admin cambian el logo)", async () => {
    fetchMock.mockResolvedValue(json(403, { detail: "Rol insuficiente" }))
    await expect(uploadDocumentLogo(file)).rejects.toMatchObject({ status: 403, code: "http_403" })
  })

  it("una respuesta 200 sin descriptor válido es un error, no un logo", async () => {
    fetchMock.mockResolvedValue(json(200, { nada: true }))
    await expect(uploadDocumentLogo(file)).rejects.toBeInstanceOf(DocumentLogoError)
  })
})

describe("logoErrorMessage", () => {
  const err = (code: string, status: number) => new DocumentLogoError(code, "x", status)

  it.each([
    ["branding_logo_too_large", 413, /2 MB/],
    ["branding_logo_unsupported_type", 415, /PNG, JPEG o WebP/],
    ["branding_logo_invalid", 422, /dañada|no se pudo leer/i],
    ["branding_logo_too_heavy", 422, /pesa demasiado/i],
    ["http_403", 403, /dueño|administrador/i],
  ])("%s → mensaje en castellano", (code, status, pattern) => {
    expect(logoErrorMessage(err(code, status))).toMatch(pattern)
  })

  it("cualquier otro error tiene un mensaje genérico, nunca el texto técnico", () => {
    expect(logoErrorMessage(new Error("Failed to fetch"))).toMatch(/No se pudo subir el logo/)
    expect(logoErrorMessage(err("http_500", 500))).toMatch(/No se pudo subir el logo/)
  })
})

describe("validateLogoFile (chequeo previo, para dar el mensaje antes de subir)", () => {
  const make = (name: string, type: string, size = 10) =>
    new File([new Uint8Array(size)], name, { type })

  it.each(["image/png", "image/jpeg", "image/webp"])("acepta %s", (type) => {
    expect(validateLogoFile(make("a", type))).toBeNull()
  })

  it.each(["image/svg+xml", "image/gif", "application/pdf", "text/plain", ""])("rechaza el tipo %j", (type) => {
    expect(validateLogoFile(make("a", type))).toMatch(/PNG, JPEG o WebP/)
  })

  it("rechaza lo que pesa más de 2 MB", () => {
    expect(validateLogoFile(make("a", "image/png", LOGO_MAX_UPLOAD_BYTES + 1))).toMatch(/2 MB/)
    expect(validateLogoFile(make("a", "image/png", LOGO_MAX_UPLOAD_BYTES))).toBeNull()
  })
})

describe("fetchDocumentLogoDataUri", () => {
  it("GET con la huella como ?v= y la sesión; devuelve un data: URI", async () => {
    fetchMock.mockResolvedValue(new Response(new Uint8Array([137, 80, 78, 71]), { status: 200, headers: { "Content-Type": "image/png" } }))

    const uri = await fetchDocumentLogoDataUri("a".repeat(64))

    expect(fetchMock).toHaveBeenCalledWith(
      `http://api.test/document-branding/logo?v=${"a".repeat(64)}`,
      { method: "GET", headers: { Authorization: "Bearer tok-1" } },
    )
    expect(uri).toMatch(/^data:image\/png;base64,[A-Za-z0-9+/]+=*$/)
    expect(atob(uri!.split(",")[1])).toBe("\x89PNG")
  })

  it("un contenido que no es PNG/JPEG no se convierte en data: (nunca un SVG)", async () => {
    fetchMock.mockResolvedValue(new Response("<svg/>", { status: 200, headers: { "Content-Type": "image/svg+xml" } }))
    expect(await fetchDocumentLogoDataUri("b".repeat(64))).toBeNull()
  })

  it("un 404 (la cuenta no tiene logo) devuelve null sin lanzar", async () => {
    fetchMock.mockResolvedValue(json(404, { code: "branding_logo_not_found" }, "application/problem+json"))
    expect(await fetchDocumentLogoDataUri("c".repeat(64))).toBeNull()
  })

  it("un 401 que ya navegó al login devuelve null", async () => {
    fetchMock.mockResolvedValue(new Response("", { status: 401 }))
    redirectedMock.mockResolvedValue(true)
    expect(await fetchDocumentLogoDataUri("d".repeat(64))).toBeNull()
  })

  it("una huella con forma rara no llega a la URL", async () => {
    expect(await fetchDocumentLogoDataUri("../../etc/passwd")).toBeNull()
    expect(fetchMock).not.toHaveBeenCalled()
  })
})

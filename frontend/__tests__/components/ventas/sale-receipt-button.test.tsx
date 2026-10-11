/**
 * fix/comprobante-print-csp-nonce.
 *
 * "Ventas → Comprobante → Descargar / Imprimir" abre el HTML en una pestaña
 * `blob:`. Bajo la CSP con nonce (`lib/supabase/middleware.ts`), ese
 * documento sólo puede ejecutar su `<script>` de auto-impresión si lleva el
 * nonce vigente — y `handleDownload` tiene que leerlo del documento actual
 * (`lib/script-nonce.ts`) y pasárselo a `generateReceiptHTML`. Sin eso, la
 * pestaña se abre pero el diálogo de impresión nunca aparece: el bug
 * reportado por el PO.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

import { SaleReceiptButton } from "@/components/ventas/sale-receipt-button"
import type { SaleOperation } from "@/lib/group-operations"
import type { Sale } from "@/lib/types"
import { pythonClient } from "@/lib/api/python-client"
import { fetchDocumentLogoDataUri } from "@/lib/api/document-logo"
import { BRANDING_RESPONSE, LOGO_SHA, PNG_DATA_URI, renderWithClient } from "../../helpers/branding-fixtures"

// documentos-marca-empresa: el comprobante lee la MARCA de la cuenta (GET /document-branding),
// no el perfil del usuario. Estos tests montan el botón con un QueryClient y mockean los dos
// transportes de la marca.
vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), patch: vi.fn(), delete: vi.fn() },
}))
// El PDF del comprobante interno (WhatsApp) pide su sesión con los encabezados de auth.
vi.mock("@/lib/api/auth-headers", () => ({
  getAuthHeaders: vi.fn(async (extra?: Record<string, string>) => ({ ...(extra ?? {}), Authorization: "Bearer tok-1" })),
  tokenFromHeaders: () => "tok-1",
  redirectedOnUnauthorized: vi.fn(async () => false),
}))
vi.mock("@/lib/api/document-logo", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/api/document-logo")>()
  return { ...actual, fetchDocumentLogoDataUri: vi.fn() }
})

// ventas-unidades-conversion (6.3): el botón resuelve el símbolo de la unidad
// de cada línea con useUnitsOfMeasure — sin mock, el hook real crea el
// cliente de Supabase (sin NEXT_PUBLIC_SUPABASE_URL en el entorno de test).
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: [], unitsById: new Map(), loading: false, error: null }),
}))
vi.mock("sonner", () => ({
  toast: { success: vi.fn(), error: vi.fn(), info: vi.fn() },
}))
// El perfil del usuario que imprime YA NO se usa: estos valores no deben aparecer en ningún
// papel (el nombre, el teléfono, el email de login ni el avatar son de la persona, no de la cuenta).
vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({
    user: {
      businessName: "Perfil Usuario",
      name: "Perfil Usuario",
      phone: "2611111111",
      email: "login@usuario.test",
      avatar: "https://avatar.test/yo.png",
    },
  }),
}))

function makeItem(overrides: Partial<Sale> = {}): Sale {
  return {
    id: "s1",
    date: "2026-09-18",
    productId: "p1",
    productName: "Producto A",
    clientId: "c1",
    clientName: "Consumidor Final",
    quantity: 1,
    unitPrice: 100,
    total: 100,
    currency: "ARS",
    ...overrides,
  }
}

function makeOp(overrides: Partial<SaleOperation> = {}): SaleOperation {
  return {
    key: "op1",
    operationId: "op1",
    date: "2026-09-18",
    clientId: "c1",
    clientName: "Consumidor Final",
    currency: "ARS",
    items: [makeItem()],
    total: 100,
    isGrouped: false,
    paymentMethodId: null,
    branchId: null,
    canal: null,
    unitId: null,
    isFiscallyLocked: false,
    fiscal: null,
    isPaymentLocked: false,
    hasAccountCharge: false,
    hasCashMovement: false,
    hasBankMovement: false, sourceQuoteId: null, sourceQuoteNumber: null, hasServiceLines: false,
    ...overrides,
  }
}

/** Abre el dropdown "Comprobante" y elige "Descargar / Imprimir". */
async function clickDownloadPrint() {
  const user = userEvent.setup()
  renderWithClient(<SaleReceiptButton op={makeOp()} clientPhone={null} clientFirstName={null} />)

  await user.click(screen.getByRole("button", { name: /comprobante/i }))
  await user.click(await screen.findByText("Descargar / Imprimir"))
}

beforeEach(() => {
  vi.mocked(pythonClient.get).mockReset()
  vi.mocked(pythonClient.get).mockResolvedValue(BRANDING_RESPONSE)
  vi.mocked(fetchDocumentLogoDataUri).mockReset()
  vi.mocked(fetchDocumentLogoDataUri).mockResolvedValue(PNG_DATA_URI)
})

describe("SaleReceiptButton — Descargar / Imprimir bajo CSP con nonce", () => {
  let nonceScript: HTMLScriptElement | undefined

  afterEach(() => {
    nonceScript?.remove()
    nonceScript = undefined
    vi.restoreAllMocks()
  })

  it("el Blob que se abre en la pestaña nueva lleva el nonce vigente del documento", async () => {
    nonceScript = document.createElement("script")
    nonceScript.setAttribute("nonce", "DOC-N0NC3-123")
    document.head.appendChild(nonceScript)

    let capturedBlob: Blob | undefined
    const createObjectURLSpy = vi
      .spyOn(URL, "createObjectURL")
      .mockImplementation((blob: Blob | MediaSource) => {
        capturedBlob = blob as Blob
        return "blob:mock-url-1"
      })
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {})
    const openSpy = vi.spyOn(window, "open").mockReturnValue({} as Window)

    await clickDownloadPrint()

    await waitFor(() => expect(createObjectURLSpy).toHaveBeenCalledTimes(1))
    expect(capturedBlob).toBeInstanceOf(Blob)
    const html = await capturedBlob!.text()
    expect(html).toContain('<script nonce="DOC-N0NC3-123">')

    expect(openSpy).toHaveBeenCalledWith("blob:mock-url-1", "_blank")
  })

  it("sin ningún <script nonce> en el documento, el Blob sale sin el atributo (no 'undefined' literal)", async () => {
    // Deliberadamente sin montar ningún <script nonce> esta vez.
    let capturedBlob: Blob | undefined
    vi.spyOn(URL, "createObjectURL").mockImplementation((blob: Blob | MediaSource) => {
      capturedBlob = blob as Blob
      return "blob:mock-url-2"
    })
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {})
    vi.spyOn(window, "open").mockReturnValue({} as Window)

    await clickDownloadPrint()

    await waitFor(() => expect(capturedBlob).toBeDefined())
    const html = await capturedBlob!.text()
    expect(html).toContain("<script>")
    expect(html).not.toContain("nonce=")
  })

  it("con el popup bloqueado (window.open devuelve null), cae al <a download>", async () => {
    vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:mock-url-3")
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {})
    vi.spyOn(window, "open").mockReturnValue(null)

    let clickedAnchor: { href: string; download: string } | undefined
    vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(function (
      this: HTMLAnchorElement,
    ) {
      clickedAnchor = { href: this.href, download: this.download }
    })

    await clickDownloadPrint()

    await waitFor(() => expect(clickedAnchor).toBeDefined())
    expect(clickedAnchor!.href).toContain("blob:mock-url-3")
    expect(clickedAnchor!.download).toBe("comprobante-op1.html")
  })
})


// ══════════════════════════════════════════════════════════════════════════════
// documentos-marca-empresa (task 10.3) — el comprobante lleva la MARCA de la cuenta
// (la que resuelve el servidor y lee GET /document-branding), nunca el perfil, el avatar ni
// el email de login del usuario que lo imprime.
// ══════════════════════════════════════════════════════════════════════════════

/** Captura el HTML que se abre en la pestaña y devuelve su texto. */
function captureOpenedHtml() {
  let capturedBlob: Blob | undefined
  vi.spyOn(URL, "createObjectURL").mockImplementation((blob: Blob | MediaSource) => {
    capturedBlob = blob as Blob
    return "blob:mock-brand"
  })
  vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {})
  return {
    html: async () => {
      await waitFor(() => expect(capturedBlob).toBeDefined())
      return capturedBlob!.text()
    },
  }
}

describe("SaleReceiptButton — la marca de la cuenta", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("el HTML lleva el nombre, el contacto, la leyenda y la paleta de la CUENTA, no los del usuario", async () => {
    const opened = captureOpenedHtml()
    vi.spyOn(window, "open").mockReturnValue({} as Window)

    await clickDownloadPrint()

    const html = await opened.html()
    expect(html).toContain("Sumar Ropa Deportiva")
    expect(html).toContain("2617175072")
    expect(html).toContain("ventas@sumar.com.ar")
    expect(html).toContain("sumar.com.ar")
    expect(html).toContain("Alias para transferencias: sumar.ropa")
    expect(html).toContain("--heading: #1d4ed8")
    // nada del perfil del usuario que imprime
    for (const leaked of ["Perfil Usuario", "2611111111", "login@usuario.test", "avatar.test", "yo.png"]) {
      expect(html, leaked).not.toContain(leaked)
    }
    expect(html).not.toMatch(/emerald|#059669/i)
    expect(pythonClient.get).toHaveBeenCalledWith("/document-branding")
  })

  it("el logo de la cuenta entra como imagen data:, no como la URL del avatar", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue({
      ...BRANDING_RESPONSE,
      logo: { sha256: LOGO_SHA, mime: "image/png", width: 400, height: 100 },
    })
    const opened = captureOpenedHtml()
    vi.spyOn(window, "open").mockReturnValue({} as Window)

    await clickDownloadPrint()

    const html = await opened.html()
    expect(html).toContain(`<img class="business-logo" src="${PNG_DATA_URI}"`)
    expect(fetchDocumentLogoDataUri).toHaveBeenCalledWith(LOGO_SHA)
    expect(html).not.toContain("avatar.test")
  })

  it("abrir el menú PRECARGA la marca y el logo, antes de elegir nada", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue({
      ...BRANDING_RESPONSE,
      logo: { sha256: LOGO_SHA, mime: "image/png", width: 400, height: 100 },
    })
    const user = userEvent.setup()
    renderWithClient(<SaleReceiptButton op={makeOp()} clientPhone={null} clientFirstName={null} />)
    expect(pythonClient.get).not.toHaveBeenCalled()                  // no se pide al montar la fila

    await user.click(screen.getByRole("button", { name: /comprobante/i }))

    await waitFor(() => expect(pythonClient.get).toHaveBeenCalledWith("/document-branding"))
    await waitFor(() => expect(fetchDocumentLogoDataUri).toHaveBeenCalledWith(LOGO_SHA))
  })

  it("con la marca ya cargada, abre la pestaña EN el gesto con la URL del comprobante (como siempre)", async () => {
    const opened = captureOpenedHtml()
    const openSpy = vi.spyOn(window, "open").mockReturnValue({} as Window)
    const user = userEvent.setup()
    renderWithClient(<SaleReceiptButton op={makeOp()} clientPhone={null} clientFirstName={null} />)
    await user.click(screen.getByRole("button", { name: /comprobante/i }))        // precarga
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())
    await new Promise((resolve) => setTimeout(resolve, 20))                       // deja resolver la precarga

    await user.click(await screen.findByText("Descargar / Imprimir"))

    await opened.html()
    expect(openSpy).toHaveBeenCalledTimes(1)
    expect(openSpy).toHaveBeenCalledWith("blob:mock-brand", "_blank")
  })

  it("si la marca todavía no llegó al hacer clic, abre la pestaña PRIMERO y la llena cuando llega", async () => {
    let resolveBranding!: (value: unknown) => void
    vi.mocked(pythonClient.get).mockImplementation(() => new Promise((resolve) => { resolveBranding = resolve }))
    const opened = captureOpenedHtml()
    const tab = { location: { href: "" }, close: vi.fn() }
    const openSpy = vi.spyOn(window, "open").mockReturnValue(tab as unknown as Window)

    await clickDownloadPrint()

    // dentro del gesto: pestaña vacía abierta, sin HTML todavía
    expect(openSpy).toHaveBeenCalledWith("", "_blank")
    expect(tab.location.href).toBe("")
    expect(URL.createObjectURL).not.toHaveBeenCalled()

    resolveBranding(BRANDING_RESPONSE)

    await waitFor(() => expect(tab.location.href).toBe("blob:mock-brand"))
    expect(await opened.html()).toContain("Sumar Ropa Deportiva")
    expect(tab.close).not.toHaveBeenCalled()
  })

  it("con el popup bloqueado y la marca pendiente, descarga el HTML cuando llega", async () => {
    let resolveBranding!: (value: unknown) => void
    vi.mocked(pythonClient.get).mockImplementation(() => new Promise((resolve) => { resolveBranding = resolve }))
    captureOpenedHtml()
    vi.spyOn(window, "open").mockReturnValue(null)
    let clicked: { download: string } | undefined
    vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(function (this: HTMLAnchorElement) {
      clicked = { download: this.download }
    })

    await clickDownloadPrint()
    resolveBranding(BRANDING_RESPONSE)

    await waitFor(() => expect(clicked).toBeDefined())
    expect(clicked!.download).toBe("comprobante-op1.html")
  })

  it("si la marca no se puede cargar, imprime con el diseño básico (Neutro, sin logo) y avisa", async () => {
    const { toast } = await import("sonner")
    vi.mocked(pythonClient.get).mockRejectedValue(new Error("backend dormido"))
    const opened = captureOpenedHtml()
    const tab = { location: { href: "" }, close: vi.fn() }
    vi.spyOn(window, "open").mockReturnValue(tab as unknown as Window)

    await clickDownloadPrint()

    const html = await opened.html()
    expect(html).toContain("Mi Negocio")
    expect(html).toContain("--heading: #1e293b")
    expect(html).not.toContain("<img")
    expect(html).not.toContain("Perfil Usuario")
    expect(toast.info).toHaveBeenCalledWith(expect.stringMatching(/diseño básico/i))
    expect(tab.location.href).toBe("blob:mock-brand")                 // la pestaña ya abierta se llena igual
  })

  it("«Copiar texto» lleva el contacto del NEGOCIO y nunca el email de login", async () => {
    const user = userEvent.setup()
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText } })   // userEvent.setup() instala su propio stub: va después
    renderWithClient(<SaleReceiptButton op={makeOp()} clientPhone={null} clientFirstName={null} />)

    await user.click(screen.getByRole("button", { name: /comprobante/i }))
    await user.click(await screen.findByText("Copiar texto"))

    await waitFor(() => expect(writeText).toHaveBeenCalledTimes(1))
    const text = writeText.mock.calls[0][0] as string
    expect(text).toContain("Sumar Ropa Deportiva")
    expect(text).toContain("2617175072")
    expect(text).toContain("ventas@sumar.com.ar")
    expect(text).not.toContain("login@usuario.test")
    expect(text).not.toContain("Perfil Usuario")
  })

  it("el PDF por WhatsApp se pide SIN datos del negocio (los resuelve el servidor) y el mensaje nombra a la cuenta", async () => {
    const share = vi.fn().mockResolvedValue(undefined)
    Object.assign(navigator, { canShare: () => true, share })
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue({
      ok: true,
      status: 200,
      blob: async () => new Blob(["%PDF-1.4"], { type: "application/pdf" }),
    } as unknown as Response)
    const user = userEvent.setup()
    renderWithClient(<SaleReceiptButton op={makeOp()} clientPhone="2615551234" clientFirstName="Ana" />)

    await user.click(screen.getByRole("button", { name: /whatsapp/i }))

    await waitFor(() => expect(share).toHaveBeenCalledTimes(1))
    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(url).toBe(`${process.env.NEXT_PUBLIC_BACKEND_URL}/sales/receipt-pdf`)
    const body = JSON.parse(init.body as string) as Record<string, unknown>
    for (const key of ["business_name", "business_phone", "business_email"]) {
      expect(body, key).not.toHaveProperty(key)
    }
    expect(JSON.stringify(body)).not.toContain("login@usuario.test")
    const data = share.mock.calls[0][0] as ShareData
    expect(data.text).toContain("*Sumar Ropa Deportiva*")
    expect(data.text).not.toContain("Perfil Usuario")
  })
})

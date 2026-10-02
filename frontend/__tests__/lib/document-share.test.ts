/**
 * presupuestos-modulo (D9, task 4.1) — helpers de compartir un PDF extraídos de
 * `sale-receipt-button.tsx` a la capa canónica `lib/document-share.ts`.
 *
 * Único cambio de contrato respecto del original: `sharePdf` distingue la
 * cancelación del usuario (`"cancelled"`) de un share exitoso (`"shared"`),
 * porque el menú de compartir no debe marcar como enviado un documento que el
 * usuario no mandó.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { downloadBlob, sharePdf, openWhatsAppText } from "@/lib/document-share"

function pdfFile(): File {
  return new File(["%PDF-1.4"], "presupuesto-P-00000012.pdf", { type: "application/pdf" })
}

describe("downloadBlob", () => {
  beforeEach(() => {
    vi.useFakeTimers()
    Object.assign(URL, {
      createObjectURL: vi.fn(() => "blob:fake-1"),
      revokeObjectURL: vi.fn(),
    })
  })
  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it("dispara la descarga con el nombre pedido y libera la URL después", () => {
    const clicks: Array<{ href: string; download: string }> = []
    const click = vi
      .spyOn(HTMLAnchorElement.prototype, "click")
      .mockImplementation(function (this: HTMLAnchorElement) {
        clicks.push({ href: this.href, download: this.download })
      })

    downloadBlob(new Blob(["x"], { type: "application/pdf" }), "presupuesto-P-00000012.pdf")

    expect(click).toHaveBeenCalledTimes(1)
    expect(clicks[0]).toEqual({ href: "blob:fake-1", download: "presupuesto-P-00000012.pdf" })
    // El <a> no queda colgado del documento
    expect(document.querySelector("a[download]")).toBeNull()
    // La URL se libera recién pasado el margen para que la lea el navegador
    expect(URL.revokeObjectURL).not.toHaveBeenCalled()
    vi.advanceTimersByTime(10_000)
    expect(URL.revokeObjectURL).toHaveBeenCalledWith("blob:fake-1")
  })

  it("usa el nombre de cada llamada (dos descargas, dos nombres)", () => {
    const names: string[] = []
    vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(function (this: HTMLAnchorElement) {
      names.push(this.download)
    })
    downloadBlob(new Blob(["a"]), "a.pdf")
    downloadBlob(new Blob(["b"]), "b.pdf")
    expect(names).toEqual(["a.pdf", "b.pdf"])
  })
})

describe("sharePdf", () => {
  const original = Object.getOwnPropertyDescriptor(navigator, "share")
  const originalCanShare = Object.getOwnPropertyDescriptor(navigator, "canShare")

  function stubNavigator(canShare: boolean, share?: () => Promise<void>) {
    Object.defineProperty(navigator, "canShare", { configurable: true, value: () => canShare })
    Object.defineProperty(navigator, "share", { configurable: true, value: share ?? (async () => undefined) })
  }

  afterEach(() => {
    if (original) Object.defineProperty(navigator, "share", original)
    else delete (navigator as unknown as Record<string, unknown>).share
    if (originalCanShare) Object.defineProperty(navigator, "canShare", originalCanShare)
    else delete (navigator as unknown as Record<string, unknown>).canShare
  })

  it("compartido -> 'shared' y manda el archivo, el texto y el título", async () => {
    const share = vi.fn(async () => undefined)
    stubNavigator(true, share)
    const file = pdfFile()

    await expect(sharePdf(file, "Hola", "Presupuesto")).resolves.toBe("shared")
    expect(share).toHaveBeenCalledWith({ files: [file], text: "Hola", title: "Presupuesto" })
  })

  it("el usuario cancela el menú nativo -> 'cancelled' (no 'shared')", async () => {
    stubNavigator(true, async () => {
      throw Object.assign(new Error("cancelado"), { name: "AbortError" })
    })
    await expect(sharePdf(pdfFile(), "t", "T")).resolves.toBe("cancelled")
  })

  it("el dispositivo no puede compartir archivos -> 'unsupported' sin llamar a share", async () => {
    const share = vi.fn(async () => undefined)
    stubNavigator(false, share)
    await expect(sharePdf(pdfFile(), "t", "T")).resolves.toBe("unsupported")
    expect(share).not.toHaveBeenCalled()
  })

  it("el share falla por otra razón (iOS) -> 'unsupported' para que el caller descargue", async () => {
    stubNavigator(true, async () => {
      throw Object.assign(new Error("not allowed"), { name: "NotAllowedError" })
    })
    await expect(sharePdf(pdfFile(), "t", "T")).resolves.toBe("unsupported")
  })

  it("sin navigator.canShare -> 'unsupported'", async () => {
    delete (navigator as unknown as Record<string, unknown>).canShare
    await expect(sharePdf(pdfFile(), "t", "T")).resolves.toBe("unsupported")
  })
})

describe("openWhatsAppText", () => {
  let open: ReturnType<typeof vi.spyOn>
  beforeEach(() => {
    open = vi.spyOn(window, "open").mockImplementation(() => null)
  })
  afterEach(() => vi.restoreAllMocks())

  it("con un teléfono válido abre la conversación directa y devuelve true", () => {
    const hadNumber = openWhatsAppText("0261 555-1234", "Hola Ana")
    expect(hadNumber).toBe(true)
    expect(open).toHaveBeenCalledWith(
      "https://wa.me/5492615551234?text=Hola%20Ana",
      "_blank",
      "noopener,noreferrer",
    )
  })

  it("sin teléfono abre el selector de contactos (wa.me/?text=) y devuelve false", () => {
    expect(openWhatsAppText(null, "Hola")).toBe(false)
    expect(open).toHaveBeenLastCalledWith("https://wa.me/?text=Hola", "_blank", "noopener,noreferrer")
  })

  it("con un teléfono inválido también devuelve false (no inventa un número)", () => {
    expect(openWhatsAppText("123", "Hola")).toBe(false)
    expect(open).toHaveBeenLastCalledWith("https://wa.me/?text=Hola", "_blank", "noopener,noreferrer")
  })
})

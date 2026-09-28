/**
 * balanza-etiquetas-pos (task 4.5) — `downloadTextFile` extraída de
 * `exportToCSV` (lib/excel.ts): el archivo de la balanza (D12) necesita
 * descargar SIN BOM y SIN comillas, algo que `exportToCSV` no admite.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { downloadTextFile, exportToCSV } from "@/lib/excel"

describe("downloadTextFile", () => {
  let capturedBlob: Blob | undefined
  let capturedFilename: string | undefined

  beforeEach(() => {
    capturedBlob = undefined
    capturedFilename = undefined
    vi.spyOn(URL, "createObjectURL").mockImplementation((blob: Blob | MediaSource) => {
      capturedBlob = blob as Blob
      return "blob:mock-scale-export"
    })
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {})
    vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(function (this: HTMLAnchorElement) {
      capturedFilename = this.download
    })
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("genera un Blob con el contenido exacto y el nombre de archivo pedido", async () => {
    downloadTextFile("hola;mundo\r\n", "balanza-aliadata-2026-09-28.csv", "text/csv;charset=utf-8;")
    expect(capturedBlob).toBeInstanceOf(Blob)
    const text = await capturedBlob!.text()
    expect(text).toBe("hola;mundo\r\n")
    expect(capturedFilename).toBe("balanza-aliadata-2026-09-28.csv")
  })

  it("el Blob del archivo de balanza no lleva BOM ni comillas (a diferencia de exportToCSV)", async () => {
    downloadTextFile("Verduleria;509;Zanahoria;;1250,00;0,00;p;0;\r\n", "balanza.csv", "text/csv;charset=utf-8;")
    const bytes = new Uint8Array(await capturedBlob!.arrayBuffer())
    // Firma UTF-8 del BOM (EF BB BF) — no debe estar al inicio del archivo.
    expect(!(bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf)).toBe(true)
    const text = await capturedBlob!.text()
    expect(text).not.toContain('"')
  })
})

describe("exportToCSV — sigue en verde tras la extracción (REFACTOR)", () => {
  let capturedBlob: Blob | undefined

  beforeEach(() => {
    capturedBlob = undefined
    vi.spyOn(URL, "createObjectURL").mockImplementation((blob: Blob | MediaSource) => {
      capturedBlob = blob as Blob
      return "blob:mock-export-csv"
    })
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {})
    vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => {})
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("sigue agregando el BOM y comillas por celda", async () => {
    exportToCSV([{ nombre: "Tomate", precio: 100 }], [{ key: "nombre", header: "Nombre" }, { key: "precio", header: "Precio" }], "productos")
    const bytes = new Uint8Array(await capturedBlob!.arrayBuffer())
    expect(bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf).toBe(true)
    const text = await capturedBlob!.text()
    expect(text).toContain('"Tomate"')
  })
})

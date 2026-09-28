/**
 * balanza-etiquetas-pos (task 5.1) — el gate `token-contrast-aa` sólo parsea
 * `globals.css` y sus pares canónicos: no mira componentes, así que NO cubre
 * el indicador del lector por sí solo (D9). Este test lee el archivo fuente
 * del componente y falla ante una paleta literal (emerald-/red-/green-) o
 * ante un `text-*` con alpha (p. ej. `text-primary/70`).
 */
import { describe, it, expect } from "vitest"
import fs from "node:fs"
import path from "node:path"

const SOURCE_PATH = path.resolve(__dirname, "../../components/shared/barcode-scanner-input.tsx")
const source = fs.readFileSync(SOURCE_PATH, "utf-8")

describe("barcode-scanner-input.tsx — tokens semánticos (D9)", () => {
  it("no usa paleta literal (emerald-/red-/green-)", () => {
    expect(source).not.toMatch(/emerald-/)
    expect(source).not.toMatch(/\bred-/)
    expect(source).not.toMatch(/\bgreen-/)
  })

  it("ningún text-* lleva alpha (p. ej. text-primary/70)", () => {
    const textWithAlpha = source.match(/text-(primary|success|destructive|warning|muted-foreground)\/\d+/g)
    expect(textWithAlpha).toBeNull()
  })

  it("usa los pares canónicos medidos por token-contrast-aa", () => {
    expect(source).toContain("text-success")
    expect(source).toContain("bg-success/15")
    expect(source).toContain("text-destructive")
    expect(source).toContain("bg-destructive/15")
    expect(source).toContain("text-primary")
  })

  it("el resultado vive en una región anunciada (role=status, aria-live=polite)", () => {
    expect(source).toContain('role="status"')
    expect(source).toContain('aria-live="polite"')
  })

  it("el texto se trunca y el contenedor tiene un ancho máximo acotado", () => {
    expect(source).toContain("truncate")
    expect(source).toMatch(/max-w-\[\d+px\]/)
  })
})

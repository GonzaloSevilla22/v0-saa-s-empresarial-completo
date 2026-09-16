/**
 * auth-hardening-jwt-cookies — OQ-8, MINOR 5 de la revisión adversarial.
 *
 * `/dev-harness` está declarado en la allow-list pública (`lib/auth/route-access.ts`)
 * y la justificación es que **cada página se auto-gatea** con
 * `if (process.env.NODE_ENV === "production") notFound()`. El propio design
 * declara el contra de esa decisión —"un futuro `notFound()` olvidado quedaría
 * sin gate"— y lo acotaba con un comentario.
 *
 * Pero el aporte metodológico de este change es justamente reemplazar comentarios
 * por candados que leen el filesystem (D4). Este archivo le da a `/dev-harness`
 * el mismo tratamiento: una página nueva del arnés sin su guarda de producción
 * rompe CI en vez de nacer pública.
 */
import { describe, it, expect } from "vitest"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { isPublicPath } from "@/lib/auth/route-access"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const HARNESS_DIR = path.resolve(HERE, "..", "..", "app", "dev-harness")

/** Rutas relativas de todas las páginas del árbol del arnés. */
function listHarnessPages(dir: string): string[] {
  const out: string[] = []
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) out.push(...listHarnessPages(full))
    else if (/^page\.(tsx?|jsx?)$/.test(entry.name)) out.push(full)
  }
  return out.sort()
}

/**
 * ¿Tiene esa página la guarda que la hace inexistente en producción?
 *
 * Se exigen las dos mitades en la misma línea lógica: la comparación contra el
 * entorno de producción y la llamada a `notFound()`. Un archivo que importe
 * `notFound` sin invocarlo, o que compare el entorno sin cortar, no cuenta.
 */
function hasProductionGuard(source: string): boolean {
  const withoutComments = source
    .split(/\r?\n/)
    .filter((line) => !line.trimStart().startsWith("//") && !line.trimStart().startsWith("*"))
    .join("\n")
  return /process\.env\.NODE_ENV\s*===\s*["']production["'][^\n]*notFound\(\)/.test(
    withoutComments,
  )
}

describe("dev-harness — la allow-list pública apoya en un invariante, y el invariante se verifica", () => {
  it("el árbol existe y tiene páginas (el detector no mira un directorio vacío)", () => {
    const pages = listHarnessPages(HARNESS_DIR)
    expect(pages.length).toBeGreaterThanOrEqual(5)
  })

  it("toda página del arnés se auto-gatea en producción", () => {
    const pages = listHarnessPages(HARNESS_DIR)
    const sinGuarda = pages
      .filter((file) => !hasProductionGuard(fs.readFileSync(file, "utf8")))
      .map((file) => path.relative(HARNESS_DIR, file))

    expect(
      sinGuarda,
      `Páginas de /dev-harness sin \`if (process.env.NODE_ENV === "production") notFound()\`: ` +
        `${sinGuarda.join(", ")}. El árbol está en la allow-list pública (OQ-8) porque ` +
        `en producción no existe: sin la guarda, la página queda accesible ` +
        `anónimamente en prod.`,
    ).toEqual([])
  })

  it("y el árbol sigue declarado como público (si dejara de estarlo, los cinco specs de e2e/harness se rompen)", () => {
    expect(isPublicPath("/dev-harness")).toBe(true)
    expect(isPublicPath("/dev-harness/shell")).toBe(true)
  })
})

describe("dev-harness — el detector de la guarda no es vacuo", () => {
  it("una página nueva sin guarda aparece señalada (fixture en disco)", () => {
    const fixture = fs.mkdtempSync(path.join(os.tmpdir(), "harness-guard-"))
    try {
      fs.mkdirSync(path.join(fixture, "con-guarda"))
      fs.writeFileSync(
        path.join(fixture, "con-guarda", "page.tsx"),
        [
          'import { notFound } from "next/navigation"',
          "export default function Page() {",
          '  if (process.env.NODE_ENV === "production") notFound()',
          "  return null",
          "}",
        ].join("\n"),
      )
      fs.mkdirSync(path.join(fixture, "sin-guarda"))
      fs.writeFileSync(
        path.join(fixture, "sin-guarda", "page.tsx"),
        "export default function Page() { return null }",
      )

      const pages = listHarnessPages(fixture)
      expect(pages).toHaveLength(2)

      const sinGuarda = pages
        .filter((file) => !hasProductionGuard(fs.readFileSync(file, "utf8")))
        .map((file) => path.relative(fixture, file))
      expect(sinGuarda).toEqual([path.join("sin-guarda", "page.tsx")])
    } finally {
      fs.rmSync(fixture, { recursive: true, force: true })
    }
  })

  it("una guarda que sólo aparece en un comentario no cuenta", () => {
    const comentada = [
      "// if (process.env.NODE_ENV === \"production\") notFound()",
      "export default function Page() { return null }",
    ].join("\n")
    expect(hasProductionGuard(comentada)).toBe(false)
  })

  it("importar notFound sin invocarlo tampoco cuenta", () => {
    const importaSinCortar = [
      'import { notFound } from "next/navigation"',
      'const esProd = process.env.NODE_ENV === "production"',
      "export default function Page() { return null }",
    ].join("\n")
    expect(hasProductionGuard(importaSinCortar)).toBe(false)
  })
})

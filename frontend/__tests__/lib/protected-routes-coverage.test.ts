/**
 * auth-hardening-jwt-cookies — D4: cobertura de rutas por construcción.
 *
 * El candado: `app/(dashboard)/` se lee del **sistema de archivos** y cada árbol
 * de ruta tiene que quedar protegido. Enumerar prefijos a mano fue exactamente
 * el mecanismo que produjo F1 (12 de los 29 árboles del dashboard nacieron sin
 * gate: banco, caja, cobranzas, estadisticas, exportaciones, facturacion,
 * finanzas, organizacion, planes, rentabilidad, reportes, sucursales — medidos
 * en prod el 2026-09-16 devolviendo 200 anónimo).
 *
 * ALCANCE EXPLÍCITO (OQ-8): este test recorre **sólo** `app/(dashboard)`.
 * `app/dev-harness/**` queda **fuera de su alcance a propósito**: vive fuera del
 * grupo `(dashboard)`, se auto-gatea con `notFound()` en producción (p. ej.
 * `app/dev-harness/shell/page.tsx`) y es lo que ejercitan los cinco specs de
 * `e2e/harness/`. Este archivo NO declara cobertura sobre ese árbol.
 */
import { describe, it, expect } from "vitest"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { isProtectedPath, isApiPath, isPublicPath, PUBLIC_PREFIXES } from "@/lib/auth/route-access"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const DASHBOARD_DIR = path.resolve(HERE, "..", "..", "app", "(dashboard)")

/**
 * Los 17 prefijos enumerados a mano que regían antes de este change
 * (`lib/supabase/middleware.ts:57-61`). Se conservan acá **como fixture
 * histórico**: son el predicado contra el que el detector de abajo tiene que
 * seguir señalando los 12 árboles descubiertos. Si el detector dejara de
 * detectarlos, el test de cobertura real sería vacuo.
 */
const LEGACY_ENUMERATED_PREFIXES = [
  "/dashboard", "/ventas", "/compras", "/productos", "/stock",
  "/clientes", "/proveedores", "/gastos", "/insights", "/simulador", "/comunidad",
  "/cursos", "/configuracion", "/copiloto-ia", "/ferias", "/seguros", "/admin",
]

const legacyIsProtected = (pathname: string): boolean =>
  LEGACY_ENUMERATED_PREFIXES.some((p) => pathname.startsWith(p))

/**
 * Árboles de ruta reales de un directorio del App Router: subdirectorios,
 * ignorando los privados (`_algo`, que Next no rutea) y los grupos de ruta
 * (`(algo)`, que no aportan segmento a la URL).
 */
function listRouteTrees(dir: string): string[] {
  return fs
    .readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => e.name)
    .filter((name) => !name.startsWith("_") && !name.startsWith("("))
    .sort()
}

/** Árboles que el predicado de protección NO cubre. */
function uncoveredRouteTrees(
  trees: string[],
  isProtected: (pathname: string) => boolean,
): string[] {
  return trees.filter((tree) => !isProtected(`/${tree}`))
}

describe("D4 — cobertura de rutas del área autenticada por construcción", () => {
  it("lee árboles reales de app/(dashboard) (no una lista quemada en el test)", () => {
    const trees = listRouteTrees(DASHBOARD_DIR)
    // Cota inferior deliberadamente floja: sólo prueba que el lector ve el
    // árbol real. La aserción sustantiva es la de cobertura, abajo.
    expect(trees.length).toBeGreaterThanOrEqual(20)
    expect(trees).toContain("ventas")
    expect(trees).toContain("caja")
  })

  it("ningún árbol de app/(dashboard) queda sin cobertura", () => {
    const trees = listRouteTrees(DASHBOARD_DIR)
    const uncovered = uncoveredRouteTrees(trees, isProtectedPath)
    expect(
      uncovered,
      `Árboles de app/(dashboard) sin gate de sesión: ${uncovered.join(", ")}. ` +
        `Una ruta nueva no se agrega a ninguna lista: si aparece acá es porque su ` +
        `nombre colisiona con la allow-list pública (${PUBLIC_PREFIXES.join(", ")}).`,
    ).toEqual([])
  })

  // ── El detector no es vacuo: contra el predicado legacy señala los 12 ──────
  it("el detector señala exactamente los 12 árboles que la lista enumerada dejaba afuera", () => {
    const trees = listRouteTrees(DASHBOARD_DIR)
    const uncovered = uncoveredRouteTrees(trees, legacyIsProtected)
    expect(uncovered).toEqual([
      "banco",
      "caja",
      "cobranzas",
      "estadisticas",
      "exportaciones",
      "facturacion",
      "finanzas",
      "organizacion",
      "planes",
      "rentabilidad",
      "reportes",
      "sucursales",
    ])
  })

  // ── 12.4: un árbol nuevo sin cobertura hace fallar la suite ────────────────
  it("un árbol de ruta nuevo sin cobertura aparece como descubierto (fixture en disco)", () => {
    const fixture = fs.mkdtempSync(path.join(os.tmpdir(), "route-coverage-"))
    try {
      fs.mkdirSync(path.join(fixture, "nueva-ruta-sin-gate"))
      fs.mkdirSync(path.join(fixture, "_componentes-privados"))
      fs.mkdirSync(path.join(fixture, "(grupo-de-ruta)"))
      fs.mkdirSync(path.join(fixture, "auth"))

      const trees = listRouteTrees(fixture)
      expect(trees).toEqual(["auth", "nueva-ruta-sin-gate"])

      // Contra el predicado real: "auth" queda descubierto porque su nombre
      // colisiona con la allow-list pública — ése es el modo de falla que la
      // protección por defecto puede tener, y el candado lo atrapa.
      expect(uncoveredRouteTrees(trees, isProtectedPath)).toEqual(["auth"])

      // Contra el predicado legacy, una ruta nueva cualquiera queda descubierta:
      // es el mecanismo exacto que produjo F1.
      expect(uncoveredRouteTrees(trees, legacyIsProtected)).toEqual([
        "auth",
        "nueva-ruta-sin-gate",
      ])
    } finally {
      fs.rmSync(fixture, { recursive: true, force: true })
    }
  })
})

// ── Revisión adversarial (MAJOR 1): el candado simétrico ───────────────────
// El candado de arriba cubre UNA dirección: que ningún árbol del área
// autenticada nazca sin gate. Con "protección por defecto" existe el modo de
// falla inverso, igual de silencioso: un árbol **público** nuevo
// (`app/precios/page.tsx`, una landing de precios) nace **detrás del login para
// todo visitante anónimo** y ningún test falla. Este describe lo cierra leyendo
// `app/` del filesystem y exigiendo que cada árbol público real esté declarado
// en la allow-list.
//
// `api` queda fuera a propósito: es la tercera categoría (ni pública ni
// gateada por redirect), ya cubierta por su propio describe más abajo.
const APP_DIR = path.resolve(HERE, "..", "..", "app")

/** ¿Tiene ese directorio al menos un archivo de ruta del App Router? */
function hasRouteFile(dir: string): boolean {
  return fs.readdirSync(dir, { withFileTypes: true }).some((entry) => {
    if (entry.isDirectory()) return hasRouteFile(path.join(dir, entry.name))
    return /^(page|route)\.(tsx?|jsx?)$/.test(entry.name)
  })
}

/**
 * Árboles de ruta de `app/` que NO pertenecen al área autenticada: candidatos a
 * superficie pública. Se excluyen los grupos de ruta (`(dashboard)` es el área
 * autenticada y tiene su propio candado), los privados, `api` y los
 * directorios que no contienen ninguna ruta (`actions/` sólo tiene módulos de
 * Server Actions, no rutea).
 */
function listNonDashboardRouteTrees(dir: string): string[] {
  return fs
    .readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => e.name)
    .filter((name) => !name.startsWith("_") && !name.startsWith("(") && name !== "api")
    .filter((name) => hasRouteFile(path.join(dir, name)))
    .sort()
}

describe("D4 — candado simétrico: ningún árbol público nace gateado", () => {
  it("lee los árboles reales de app/ que no son el área autenticada", () => {
    const trees = listNonDashboardRouteTrees(APP_DIR)
    // Los cuatro de hoy: auth, dev-harness, landing, legal.
    expect(trees).toEqual(["auth", "dev-harness", "landing", "legal"])
  })

  it("todos están declarados en la allow-list pública", () => {
    const trees = listNonDashboardRouteTrees(APP_DIR)
    const gated = trees.filter((tree) => !isPublicPath(`/${tree}`))
    expect(
      gated,
      `Árboles fuera de app/(dashboard) que quedaron detrás del login: ${gated.join(", ")}. ` +
        `Con protección por defecto, una superficie pública nueva hay que declararla ` +
        `en PUBLIC_PREFIXES (${PUBLIC_PREFIXES.join(", ")}) o queda invisible para ` +
        `todo visitante anónimo.`,
    ).toEqual([])
  })

  it("el detector no es vacuo: un árbol público nuevo sin declarar aparece gateado (fixture en disco)", () => {
    const fixture = fs.mkdtempSync(path.join(os.tmpdir(), "public-coverage-"))
    try {
      // Una landing de precios nueva, con su page.tsx, no declarada.
      fs.mkdirSync(path.join(fixture, "precios"))
      fs.writeFileSync(path.join(fixture, "precios", "page.tsx"), "export default () => null")
      // Un árbol ya declarado, para el contraste.
      fs.mkdirSync(path.join(fixture, "legal"))
      fs.writeFileSync(path.join(fixture, "legal", "page.tsx"), "export default () => null")
      // Un directorio sin ruta: no es superficie, no debe pedir declaración.
      fs.mkdirSync(path.join(fixture, "actions"))
      fs.writeFileSync(path.join(fixture, "actions", "landing.ts"), "export const noop = 1")

      const trees = listNonDashboardRouteTrees(fixture)
      expect(trees).toEqual(["legal", "precios"])
      expect(trees.filter((t) => !isPublicPath(`/${t}`))).toEqual(["precios"])
    } finally {
      fs.rmSync(fixture, { recursive: true, force: true })
    }
  })
})

// ── Revisión adversarial (MINOR 2): los assets que D4 declara ──────────────
// D4 enumera la allow-list como "`/`, `/auth/*`, `/legal/*`, landing, **assets**",
// pero la allow-list no tenía ninguna regla de assets: lo único que salvaba a
// `public/` era el matcher del middleware, que excluye SÓLO
// svg|png|jpg|jpeg|gif|webp. Los 16 archivos de `public/` de hoy son todos de
// esas extensiones (sin regresión viva), pero el primer .woff2, .glb, .ktx2,
// .hdr, .wasm o .pdf que alguien ponga ahí queda con un 307 al login para
// cualquier visitante anónimo — y `public/3d/` es justo donde caería un decoder.
describe("D4 — los archivos estáticos no quedan detrás del login", () => {
  it.each([
    "/fonts/inter-latin.woff2",
    "/fonts/inter.ttf",
    "/3d/draco_decoder.wasm",
    "/3d/modelo.glb",
    "/3d/entorno.hdr",
    "/3d/textura.ktx2",
    "/documentos/instructivo.pdf",
    "/aliadata-logo.png",
    "/videos/tutorial.mp4",
  ])("%s es público", (pathname) => {
    expect(isProtectedPath(pathname)).toBe(false)
  })

  it("pero una ruta con un punto que NO es un asset sigue protegida", () => {
    // La regla es un conjunto CERRADO de extensiones de archivo estático, no
    // "cualquier segmento con punto": si no, un identificador con punto en una
    // ruta dinámica abriría la ruta entera.
    expect(isProtectedPath("/ventas/ordenes/2b9f4f5e.v2")).toBe(true)
    expect(isProtectedPath("/clientes/juan.perez")).toBe(true)
    expect(isProtectedPath("/estadisticas/productos/abc.def")).toBe(true)
  })

  it("y la extensión se mira en el último segmento, no en cualquier parte", () => {
    expect(isProtectedPath("/reportes/marzo.png/detalle")).toBe(true)
  })
})

// ── 12.3 TRIANGULATE: /auth/* nunca entra en el conjunto protegido ──────────
describe("D4 — las rutas de autenticación nunca se gatean", () => {
  it.each([
    "/auth",
    "/auth/login",
    "/auth/register",
    "/auth/callback",
    "/auth/verify-email",
    "/auth/forgot-password",
    "/auth/reset-password",
  ])("%s no está protegida (gatearla produce un loop de redirect)", (pathname) => {
    expect(isProtectedPath(pathname)).toBe(false)
  })
})

// ── 12.7: /api/** nunca recibe redirect ────────────────────────────────────
describe("D4 — las rutas de API del propio dominio no se redirigen", () => {
  it.each([
    "/api/auth/token",
    "/api/ai/copilot",
    "/api/billing/cancel",
    "/api/billing/preferences",
  ])("%s queda fuera del gate por redirect", (pathname) => {
    expect(isProtectedPath(pathname)).toBe(false)
  })

  it("pero una ruta de API NO es 'pública': es una tercera categoría", () => {
    // La distinción importa: `/api/**` queda fuera del redirect, no fuera del
    // control de acceso. Declararla pública invitaría a tratarla como la
    // landing, y cada handler tiene que seguir exigiendo sesión por su cuenta.
    expect(isApiPath("/api/auth/token")).toBe(true)
    expect(isPublicPath("/api/auth/token")).toBe(false)
    expect(PUBLIC_PREFIXES).not.toContain("/api")
  })

  it("no confunde una ruta del dashboard que empiece con las mismas letras", () => {
    expect(isApiPath("/apiarios")).toBe(false)
    expect(isProtectedPath("/apiarios")).toBe(true)
  })
})

// ── Protección por defecto: lo que no es público ni API, se protege ─────────
describe("D4 — protección por defecto", () => {
  it.each([
    "/caja",
    "/cobranzas",
    "/banco",
    "/estadisticas",
    "/exportaciones",
    "/facturacion",
    "/finanzas/conciliacion",
    "/organizacion/roles",
    "/planes",
    "/rentabilidad",
    "/reportes/comparativo",
    "/sucursales",
    "/ventas",
    "/dashboard",
  ])("%s está protegida", (pathname) => {
    expect(isProtectedPath(pathname)).toBe(true)
  })

  it.each(["/", "/landing", "/legal/terminos", "/legal/privacidad", "/dev-harness/shell"])(
    "%s es pública",
    (pathname) => {
      expect(isProtectedPath(pathname)).toBe(false)
    },
  )

  it("el manifiesto de la PWA no queda detrás del login", () => {
    // app/manifest.ts se sirve en /manifest.webmanifest y el matcher del
    // middleware NO lo excluye: protegerlo rompería la instalación de la PWA
    // para cualquier visitante anónimo.
    expect(isProtectedPath("/manifest.webmanifest")).toBe(false)
  })
})

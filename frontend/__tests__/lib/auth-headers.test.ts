/**
 * auth-hardening-jwt-cookies — D7 y D21, tasks 14.7 y 14.8.
 *
 * Dos defectos que comparten causa: cada transporte del navegador hacia el
 * backend propio armaba sus encabezados por su cuenta.
 *
 *  - Tres de ellos mandaban `Authorization: Bearer ` **vacío** cuando no había
 *    sesión, en vez de omitir el encabezado.
 *  - `python-client.ts:54` mergeaba `extraHeaders` DESPUÉS de los de auth, así
 *    que un caller podía sobrescribir `Authorization`.
 *
 * `getAuthHeaders()` es la única implementación: omite el encabezado cuando no
 * hay token y aplica los de auth ÚLTIMOS, de modo que el orden de merge deje de
 * ser una decisión de cada call site.
 *
 * `handleUnauthorized()` cierra D7: el 401 dejaba un mensaje que recomendaba
 * recargar la página, y esa recomendación delegaba la renovación en un redirect
 * del middleware que en las 12 rutas de F1 **nunca ocurría**.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

/**
 * Parte C, task 19.8f: el seam pasa de `supabase.auth.getSession()` al store del
 * token (`lib/auth/access-token-store.ts`). Mockear `@/lib/supabase/client` acá
 * dejaría el test verde mientras producción lanza: con `accessToken` configurado
 * `supabase.auth` es un Proxy que tira en cualquier acceso
 * (`supabase-js/index.mjs:389`). El candado de 19.7b prohíbe ese doble.
 *
 * El store ya devuelve los **tres** estados que este módulo necesita (`active` /
 * `absent` / `unknown`), así que la traducción desaparece: lo que antes era "la
 * consulta lanzó" ahora es un valor de retorno.
 */
const resolveAccessTokenMock = vi.fn()

vi.mock("@/lib/auth/access-token-store", () => ({
  resolveAccessToken: (options?: { force?: boolean }) => resolveAccessTokenMock(options),
}))

import {
  getAuthHeaders,
  handleUnauthorized,
  redirectedOnUnauthorized,
  tokenFromHeaders,
  sessionNavigation,
} from "@/lib/api/auth-headers"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const FRONTEND = path.resolve(HERE, "..", "..")

function withSession(token: string) {
  resolveAccessTokenMock.mockResolvedValue({ status: "active", token })
}
function withoutSession() {
  resolveAccessTokenMock.mockResolvedValue({ status: "absent" })
}
/** "No pude averiguarlo": el store nunca lanza, lo informa. */
function withUnknownSession() {
  resolveAccessTokenMock.mockResolvedValue({ status: "unknown" })
}

beforeEach(() => {
  vi.restoreAllMocks()
  resolveAccessTokenMock.mockReset()
})

// ── 14.8 ::omits_authorization_header_when_token_is_empty ──────────────────
describe("getAuthHeaders — nunca manda un Bearer vacío", () => {
  it("omite el encabezado cuando no hay sesión", async () => {
    withoutSession()
    const headers = await getAuthHeaders()
    expect(headers.Authorization).toBeUndefined()
    expect(Object.keys(headers)).not.toContain("Authorization")
  })

  it("omite el encabezado cuando el token es una cadena vacía", async () => {
    resolveAccessTokenMock.mockResolvedValue({ status: "active", token: "" })
    const headers = await getAuthHeaders()
    expect(headers.Authorization).toBeUndefined()
  })

  it("omite el encabezado cuando la consulta de sesión falla", async () => {
    withUnknownSession()
    const headers = await getAuthHeaders()
    expect(headers.Authorization).toBeUndefined()
  })

  it("lo incluye cuando hay token", async () => {
    withSession("tok-123")
    const headers = await getAuthHeaders()
    expect(headers.Authorization).toBe("Bearer tok-123")
  })
})

describe("getAuthHeaders — los encabezados de auth van ÚLTIMOS", () => {
  it("un caller no puede sobrescribir Authorization", async () => {
    withSession("tok-real")
    const headers = await getAuthHeaders({ Authorization: "Bearer tok-del-caller" })
    expect(headers.Authorization).toBe("Bearer tok-real")
  })

  it("los demás encabezados del caller se conservan", async () => {
    withSession("tok-123")
    const headers = await getAuthHeaders({
      "Content-Type": "application/json",
      "Idempotency-Key": "key-abc",
    })
    expect(headers).toMatchObject({
      "Content-Type": "application/json",
      "Idempotency-Key": "key-abc",
      Authorization: "Bearer tok-123",
    })
  })

  it("sin token, un Authorization del caller tampoco sobrevive con valor vacío", async () => {
    withoutSession()
    const headers = await getAuthHeaders({ "Content-Type": "application/json" })
    expect(headers).toEqual({ "Content-Type": "application/json" })
  })
})

// ── 14.7 ::401_without_session_navigates_to_login ──────────────────────────
describe("handleUnauthorized — D7", () => {
  it("sin sesión navega al login con reason=expired y el destino actual", async () => {
    withoutSession()
    const assign = vi.spyOn(sessionNavigation, "assign").mockImplementation(() => {})
    window.history.pushState({}, "", "/caja?turno=2")

    const outcome = await handleUnauthorized()

    expect(outcome).toBe("navigated")
    expect(assign).toHaveBeenCalledTimes(1)
    const url = new URL(assign.mock.calls[0][0], "https://app.test")
    expect(url.pathname).toBe("/auth/login")
    expect(url.searchParams.get("reason")).toBe("expired")
    expect(url.searchParams.get("next")).toBe("/caja?turno=2")
  })

  it("con sesión viva NO navega: el 401 fue por otra razón", async () => {
    withSession("tok-vivo")
    const assign = vi.spyOn(sessionNavigation, "assign").mockImplementation(() => {})

    const outcome = await handleUnauthorized("tok-vivo")

    expect(outcome).toBe("session-active")
    expect(assign).not.toHaveBeenCalled()
  })

  // ── Revisión adversarial (MINOR 4): "no hay sesión" ≠ "no pude averiguarlo" ──
  // El requirement dice "consultando el estado de sesión y, **cuando no exista
  // sesión**, SHALL navegar". Un fallo transitorio de la consulta —refresh token
  // perfectamente válido— no es "no existe sesión", y hasta esta revisión
  // producía una navegación dura que tira el estado de la pantalla en curso (un
  // formulario de venta a medio cargar). El test anterior fijaba esa conflación
  // como comportamiento deseado.
  it("si la consulta de sesión falla, NO navega: no saber no es no tener", async () => {
    withUnknownSession()
    const assign = vi.spyOn(sessionNavigation, "assign").mockImplementation(() => {})

    const outcome = await handleUnauthorized()

    expect(outcome).toBe("session-unknown")
    expect(assign).not.toHaveBeenCalled()
  })

  // ── Revisión adversarial (MINOR 1 de seguridad): el caso más común ──────────
  // `getSession()` **auto-refresca** contra el proveedor, así que en el caso que
  // el usuario vive de verdad —"el access token venció mientras la pantalla
  // estaba abierta"— la consulta devuelve un token NUEVO. Sin distinguirlo, el
  // transporte informaba un problema de permisos para un problema de frescura ya
  // resuelto.
  it("distingue una sesión renovada de un problema de permisos", async () => {
    withSession("tok-nuevo")
    const assign = vi.spyOn(sessionNavigation, "assign").mockImplementation(() => {})

    const outcome = await handleUnauthorized("tok-viejo")

    expect(outcome).toBe("session-renewed")
    expect(assign).not.toHaveBeenCalled()
  })

  it("sin saber qué token se envió no inventa una renovación", async () => {
    withSession("tok-vivo")
    vi.spyOn(sessionNavigation, "assign").mockImplementation(() => {})

    // Los `fetch` a mano no llevan cuenta del token enviado: para ellos la
    // sesión viva es simplemente viva.
    expect(await handleUnauthorized()).toBe("session-active")
    expect(await handleUnauthorized(null)).toBe("session-active")
  })

  it("una sesión ausente navega aunque el caller informe el token que envió", async () => {
    withoutSession()
    const assign = vi.spyOn(sessionNavigation, "assign").mockImplementation(() => {})

    expect(await handleUnauthorized("tok-viejo")).toBe("navigated")
    expect(assign).toHaveBeenCalledTimes(1)
  })

  // ── Parte C, task 19.8f ────────────────────────────────────────────────────
  // El auto-refresh de `getSession()` era lo que hacía posible `session-renewed`:
  // la consulta devolvía un token NUEVO sin que nadie lo pidiera. El store, en
  // cambio, cachea por el TTL del token, así que la consulta cacheada devolvería
  // el MISMO token que acaba de recibir el 401 y el resultado sería
  // `session-active` — un problema de permisos informado para un problema de
  // frescura. El 401 es la evidencia de que lo cacheado no sirve: acá se fuerza.
  it("el 401 fuerza la renovación en vez de creerle al caché", async () => {
    withSession("tok-nuevo")
    vi.spyOn(sessionNavigation, "assign").mockImplementation(() => {})

    await handleUnauthorized("tok-viejo")

    expect(resolveAccessTokenMock).toHaveBeenCalledWith({ force: true })
  })

  it("armar los encabezados, en cambio, NO fuerza nada", async () => {
    // Si forzara, cada llamada al backend propio sería un `GET /api/auth/token`
    // extra: el camino caliente pasa por el caché en memoria.
    withSession("tok-123")

    await getAuthHeaders()

    expect(resolveAccessTokenMock).not.toHaveBeenCalledWith({ force: true })
  })
})

// ── Revisión adversarial (MINOR 2 de seguridad) ─────────────────────────────
// Los dos `fetch` a mano hacían `if (res.status === 401) { await
// handleUnauthorized() }` y en la línea siguiente `if (!res.ok) throw …`:
// `window.location.assign()` es asíncrono, así que el usuario veía el cartel de
// error mientras la navegación salía. El idioma correcto —"si ya se manejó
// navegando, cortar"— vive acá, no copiado en cada call site.
describe("redirectedOnUnauthorized — el idioma de los fetch a mano", () => {
  const response = (status: number) => ({ status }) as Response

  it("con 401 y sin sesión, informa que ya se manejó navegando", async () => {
    withoutSession()
    const assign = vi.spyOn(sessionNavigation, "assign").mockImplementation(() => {})

    expect(await redirectedOnUnauthorized(response(401))).toBe(true)
    expect(assign).toHaveBeenCalledTimes(1)
  })

  it("con 401 y sesión viva, NO corta: el caller muestra su error", async () => {
    withSession("tok-vivo")
    const assign = vi.spyOn(sessionNavigation, "assign").mockImplementation(() => {})

    expect(await redirectedOnUnauthorized(response(401))).toBe(false)
    expect(assign).not.toHaveBeenCalled()
  })

  it("con 401 y consulta fallida tampoco corta", async () => {
    withUnknownSession()
    expect(await redirectedOnUnauthorized(response(401))).toBe(false)
  })

  it.each([200, 403, 404, 500])("un %i no consulta la sesión ni corta", async (status) => {
    withoutSession()
    const assign = vi.spyOn(sessionNavigation, "assign").mockImplementation(() => {})

    expect(await redirectedOnUnauthorized(response(status))).toBe(false)
    expect(resolveAccessTokenMock).not.toHaveBeenCalled()
    expect(assign).not.toHaveBeenCalled()
  })
})

describe("tokenFromHeaders — el formato del Bearer vive en un solo sitio", () => {
  it("extrae el token de los encabezados que armó el helper", async () => {
    withSession("tok-123")
    const headers = await getAuthHeaders()
    expect(tokenFromHeaders(headers)).toBe("tok-123")
  })

  it("devuelve null cuando no hay encabezado", async () => {
    withoutSession()
    const headers = await getAuthHeaders({ "Content-Type": "application/json" })
    expect(tokenFromHeaders(headers)).toBeNull()
  })

  it("no confunde otro esquema de autorización", () => {
    expect(tokenFromHeaders({ Authorization: "Basic dXNlcjpwYXNz" })).toBeNull()
  })
})

// ── D21: una sola implementación arma los encabezados ──────────────────────
describe("D21 — los transportes no arman el Bearer a mano", () => {
  /**
   * Los OCHO sitios que D21 enumera. La Parte B migró los cuatro que hablan con
   * FastAPI; la Parte C (task 19.8f) migra los cuatro que hablan con Edge
   * Functions, más los dos módulos donde vive el `fetch` de esos cuatro
   * (`use-export-usage` y `use-statistics-ai` reciben la llamada de
   * `ExportButton` y del panel de estadísticas) y las dos pantallas de IA que
   * llamaban a mano.
   */
  const TRANSPORTS = [
    "lib/api/python-client.ts",
    "lib/api/subscriptions-client.ts",
    "components/ventas/sale-receipt-button.tsx",
    "app/(dashboard)/admin/pagos/page.tsx",
    "hooks/auth/use-export-usage.ts",
    "hooks/data/use-statistics-ai.ts",
    "app/(dashboard)/simulador/page.tsx",
    "components/ai/PriceSuggestionModal.tsx",
    "app/(dashboard)/rentabilidad/page.tsx",
    "app/(dashboard)/reportes/comparativo/page.tsx",
  ]

  it.each(TRANSPORTS)("%s consume getAuthHeaders()", (relative) => {
    const source = fs.readFileSync(path.join(FRONTEND, relative), "utf8")
    expect(source).toContain("getAuthHeaders")
    expect(source).toContain("@/lib/api/auth-headers")
  })

  it.each(TRANSPORTS)("%s ya no construye `Bearer ${…}` por su cuenta", (relative) => {
    const source = fs.readFileSync(path.join(FRONTEND, relative), "utf8")
    const handRolled = source
      .split(/\r?\n/)
      .filter((line) => !line.trimStart().startsWith("//") && !line.trimStart().startsWith("*"))
      .filter((line) => /Bearer\s*\$\{/.test(line))
    expect(handRolled, `armado a mano en ${relative}: ${handRolled.join(" | ")}`).toEqual([])
  })

  it("el detector reconoce el armado a mano (no es vacuo)", () => {
    const offending = 'Authorization: `Bearer ${session?.access_token ?? ""}`'
    expect(/Bearer\s*\$\{/.test(offending)).toBe(true)
  })

  it("y el único sitio que compone el encabezado es el helper compartido", () => {
    const helper = fs.readFileSync(path.join(FRONTEND, "lib/api/auth-headers.ts"), "utf8")
    expect(/Bearer\s*\$\{/.test(helper)).toBe(true)
  })

  // ── Parte C, tasks 19.8f y 19.11 ──────────────────────────────────────────
  // La lista de arriba envejece: nombra los sitios que HABÍA. Este caso barre el
  // árbol entero, así que un noveno transporte que nazca mañana armando su propio
  // Bearer lo encuentra sin que nadie se acuerde de agregarlo a la lista.
  describe("barrido del árbol: nadie más compone un Bearer", () => {
    const ROOTS = ["app", "components", "hooks", "lib", "contexts", "providers"]
    /**
     * `auth-headers.ts` es el helper: es el único que compone el encabezado de la
     * sesión del usuario.
     *
     * `app/api/ai/copilot/route.ts` compone un Bearer que **no es la sesión**: es
     * la clave de OpenAI, en el servidor, hacia un tercero. Va nombrado en vez de
     * afinar la expresión para que no cuente como sesión: una expresión que
     * distinga "clave de tercero" de "token de usuario" por el nombre de la
     * variable es la clase de detector que después deja pasar el caso real.
     */
    const ALLOWED = ["lib/api/auth-headers.ts", "app/api/ai/copilot/route.ts"]

    function walk(dir: string, found: string[] = []): string[] {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name)
        if (entry.isDirectory()) {
          if (entry.name === "node_modules" || entry.name === ".next") continue
          walk(full, found)
        } else if (/\.tsx?$/.test(entry.name)) {
          found.push(full)
        }
      }
      return found
    }

    const SOURCES = ROOTS.flatMap((root) => walk(path.join(FRONTEND, root)))
    const relative = (absolute: string) =>
      path.relative(FRONTEND, absolute).replace(/\\/g, "/")

    /** Líneas de código (sin comentarios) que componen un Bearer. */
    function composingLines(absolute: string): string[] {
      return fs
        .readFileSync(absolute, "utf8")
        .split(/\r?\n/)
        .filter((line) => {
          const trimmed = line.trimStart()
          return (
            !trimmed.startsWith("//") && !trimmed.startsWith("*") && !trimmed.startsWith("/*")
          )
        })
        .filter((line) => /Bearer\s*\$\{/.test(line))
    }

    const OFFENDERS = SOURCES.map((absolute) => ({
      file: relative(absolute),
      lines: composingLines(absolute),
    })).filter((entry) => entry.lines.length > 0)

    it("el barrido lee el árbol (no es vacuo por no encontrar archivos)", () => {
      expect(SOURCES.length).toBeGreaterThan(200)
      // Y encuentra el del helper: si esto fuera 0, el detector estaría roto.
      expect(OFFENDERS.map((o) => o.file)).toContain("lib/api/auth-headers.ts")
    })

    it("cada excepción de la lista sigue existiendo y sigue componiendo un Bearer", () => {
      // Una excepción que dejó de aplicar es una excepción que tapa al próximo que
      // ocupe ese nombre de archivo.
      for (const allowed of ALLOWED) {
        expect(OFFENDERS.map((o) => o.file), allowed).toContain(allowed)
      }
    })

    it("ningún archivo fuera del helper compone un Bearer", () => {
      const detail = OFFENDERS.map((o) => `${o.file}: ${o.lines.map((l) => l.trim()).join(" | ")}`)
      expect(
        OFFENDERS.map((o) => o.file).filter((file) => !ALLOWED.includes(file)),
        `\n${detail.join("\n")}`,
      ).toEqual([])
    })
  })

  // ── Revisión adversarial (MINOR 2 de seguridad) ───────────────────────────
  // Los dos `fetch` a mano no tienen test de componente (ninguno de los dos
  // archivos tiene suite propia), así que el candado del flujo de control es
  // textual: lo que se exige es que consuman el idioma compartido —cuya unidad
  // sí está testeada arriba— **cortando** con un `return`, y que ya no quede el
  // patrón viejo de llamar y seguir.
  const RAW_FETCH_CALL_SITES = [
    "components/ventas/sale-receipt-button.tsx",
    "app/(dashboard)/admin/pagos/page.tsx",
  ]

  it.each(RAW_FETCH_CALL_SITES)("%s corta cuando el 401 ya se manejó navegando", (relative) => {
    const source = fs.readFileSync(path.join(FRONTEND, relative), "utf8")
    expect(source).toMatch(/if\s*\(await redirectedOnUnauthorized\(.*\)\)\s*return/)
  })

  it.each(RAW_FETCH_CALL_SITES)("%s ya no llama y sigue de largo", (relative) => {
    const source = fs.readFileSync(path.join(FRONTEND, relative), "utf8")
    const viejo = source
      .split(/\r?\n/)
      .filter((line) => !line.trimStart().startsWith("//"))
      .filter((line) => /status === 401.*await handleUnauthorized\(\)/.test(line))
    expect(viejo, `patrón viejo en ${relative}: ${viejo.join(" | ")}`).toEqual([])
  })

  it("el detector del patrón viejo no es vacuo", () => {
    const ofensivo = "      if (res.status === 401) { await handleUnauthorized() }"
    expect(/status === 401.*await handleUnauthorized\(\)/.test(ofensivo)).toBe(true)
  })
})

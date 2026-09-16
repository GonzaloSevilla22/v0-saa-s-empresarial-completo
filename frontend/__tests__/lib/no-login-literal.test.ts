/**
 * auth-hardening-jwt-cookies — D5, task 13.3.
 *
 * F2: cuatro Server Components redirigían a `/login`, una ruta que **no
 * existe** (el login vive en `/auth/login`). No hay `app/login/` ni un redirect
 * en `next.config.mjs`. Medido en prod el 2026-09-16: `/planes` anónimo
 * devolvía 200 con `/login;307;` en el stream, es decir 404 para el usuario.
 *
 * Tres de los cuatro eran alcanzables justamente por F1 (esas rutas no estaban
 * gateadas, así que el Server Component llegaba a ejecutarse sin sesión).
 *
 * Este candado prohíbe el literal como destino de redirección en todo el árbol
 * de páginas y manejadores.
 */
import { describe, it, expect } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const APP_DIR = path.resolve(HERE, "..", "..", "app")
const COMPONENTS_DIR = path.resolve(HERE, "..", "..", "components")
const HOOKS_DIR = path.resolve(HERE, "..", "..", "hooks")
const CONTEXTS_DIR = path.resolve(HERE, "..", "..", "contexts")
const LIB_DIR = path.resolve(HERE, "..", "..", "lib")

/**
 * El literal de ruta `"/login"` (o `'/login'`, `` `/login?…` ``, `"/login/x"`).
 *
 * Se detecta el literal, no la forma del call site: la primera versión exigía
 * `redirect(` / `push(` pegado adelante y se le escapaba
 * `NextResponse.redirect(new URL("/login", request.url))`. En este repo una
 * cadena `/login` no tiene ningún uso legítimo — el login vive en
 * `/auth/login` — así que el literal alcanza y no envejece con la sintaxis.
 *
 * `"/auth/login"` NO matchea: la comilla tiene que estar pegada a `/login`.
 * `"/login-help"` tampoco: detrás de `login` tiene que venir `?`, `#`, `/` o el
 * cierre de la cadena.
 */
const LOGIN_LITERAL = /(["'`])\/login(?=[?#/'"`])/

function sourceFiles(dir: string): string[] {
  const out: string[] = []
  const walk = (current: string) => {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const full = path.join(current, entry.name)
      if (entry.isDirectory()) {
        if (entry.name === "node_modules" || entry.name === ".next") continue
        walk(full)
      } else if (/\.(ts|tsx)$/.test(entry.name)) {
        out.push(full)
      }
    }
  }
  walk(dir)
  return out
}

/**
 * ¿Es una línea de comentario? Se excluyen del barrido: documentar la ruta rota
 * —que es justo lo que hacen los cuatro fixes de F2— no es redirigir a ella.
 */
function isCommentLine(line: string): boolean {
  const trimmed = line.trimStart()
  return trimmed.startsWith("//") || trimmed.startsWith("*") || trimmed.startsWith("/*")
}

function offendersIn(dirs: string[]): string[] {
  const offenders: string[] = []
  for (const dir of dirs) {
    for (const file of sourceFiles(dir)) {
      const lines = fs.readFileSync(file, "utf8").split(/\r?\n/)
      lines.forEach((line, index) => {
        if (isCommentLine(line)) return
        if (LOGIN_LITERAL.test(line)) {
          offenders.push(`${path.relative(path.resolve(HERE, "..", ".."), file)}:${index + 1}`)
        }
      })
    }
  }
  return offenders.sort()
}

describe("F2 — nadie redirige a la ruta de login inexistente", () => {
  it("no queda ningún destino `/login` en el árbol de páginas y manejadores", () => {
    const offenders = offendersIn([APP_DIR, COMPONENTS_DIR, HOOKS_DIR, CONTEXTS_DIR, LIB_DIR])
    expect(
      offenders,
      `El login vive en /auth/login. Redirigir a /login devuelve 404. Ofensores: ${offenders.join(", ")}`,
    ).toEqual([])
  })

  // ── El detector no es vacuo ───────────────────────────────────────────────
  it.each([
    'redirect("/login")',
    "redirect('/login')",
    'redirect("/login?next=%2Fcaja")',
    'router.push("/login")',
    'router.replace("/login")',
    'window.location.href = "/login"',
    'NextResponse.redirect(new URL("/login", request.url))',
  ])("detecta %j", (line) => {
    expect(LOGIN_LITERAL.test(line)).toBe(true)
  })

  it.each([
    'redirect("/auth/login")',
    'redirect(`/auth/login?next=${encodeURIComponent("/planes")}`)',
    'router.push("/auth/login?reason=idle")',
    '// el login vive en /login histórico',
    'const label = "Iniciar sesión"',
    'const help = "/login-help"',
  ])("no dispara con %j", (line) => {
    expect(LOGIN_LITERAL.test(line)).toBe(false)
  })

  // El barrido salta comentarios: los cuatro fixes de F2 documentan la ruta
  // rota en una línea de comentario, y eso NO es redirigir a ella.
  it.each([
    "// auth-hardening: `/login` no existe (404)",
    " * el destino `/login` quedó muerto",
    '/* redirect("/login") era el bug */',
  ])("ignora la línea de comentario %j", (line) => {
    expect(isCommentLine(line)).toBe(true)
  })

  it("pero una línea de código sí se mira", () => {
    expect(isCommentLine('    redirect("/login")')).toBe(false)
  })
})

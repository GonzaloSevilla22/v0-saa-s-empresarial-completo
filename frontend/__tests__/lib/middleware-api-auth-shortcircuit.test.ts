/**
 * auth-hardening-jwt-cookies — Parte C, D19-5 y D3. Revisión adversarial pre-merge
 * (dos revisores independientes, el mismo hallazgo).
 *
 * El matcher del middleware no excluye `/api` (`middleware.ts:29`), así que
 * **todo** `GET /api/auth/token` pasaba antes por `updateSession` →
 * `supabase.auth.getUser()`, que es una llamada de red a GoTrue y que **renueva**
 * cuando al token le faltan menos de `EXPIRY_MARGIN_MS = 3 × 30 s = 90 s`
 * (`auth-js/dist/main/GoTrueClient.js:2341-2371`,
 * `dist/main/lib/constants.js:6,9,13`). El navegador pide el token cuando le faltan
 * **≤ 60 s** (`access-token-store.ts:62`), es decir **siempre** dentro de esa
 * ventana. Dos consecuencias, las dos medidas:
 *
 *  1. **El single-flight de D19-5 era inerte**: la renovación ocurría en el
 *     middleware (otro runtime, otra instancia), fuera del `inFlight` del
 *     manejador. El test `::concurrent_requests_refresh_once` pasaba porque llama
 *     al handler directo, sin middleware — una aserción verdadera en el arnés y
 *     falsa en producción.
 *  2. **Un `GET /auth/v1/user` extra por cada pedido de token**: medido contra el
 *     GoTrue local, 3 pedidos autenticados a `/api/auth/token` → 3 `GET /user`
 *     (0.183 s / 0.219 s / 0.142 s contra 0.005 s de los anónimos). Y el recurso
 *     que se multiplica es justo el que D20 acaba de volver compartido: los rate
 *     limits de GoTrue son por IP y todo sale por la IP de egreso de Vercel.
 *
 * El middleware **no hace nada más** por esas rutas: `/api/**` nunca recibe
 * redirect (D4), el corte por inactividad sólo corre sobre rutas protegidas, y los
 * dos manejadores de `/api/auth/` leen la sesión, aplican el mismo `evaluateIdle` y
 * rotan sus cookies por su cuenta (`lib/auth/route-session.ts`). Lo único que
 * conserva del middleware es la CSP, que sí se sigue emitiendo.
 *
 * El cortocircuito es **angosto a propósito**: sólo `/api/auth/`. El resto de
 * `/api/**` mantiene su comportamiento de hoy —incluida la purga de la sesión
 * muerta— porque esos manejadores no rotan cookies por sí mismos y este change no
 * tiene por qué cambiarles el camino.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"

vi.mock("@supabase/ssr", async () => {
  const mod = await import("./helpers/middleware-harness")
  return { createServerClient: mod.createServerClientMock }
})

import { harness, resetHarness, buildRequest, isRedirect } from "./helpers/middleware-harness"
import { updateSession } from "@/lib/supabase/middleware"

const CONFIRMED = { id: "u1", email_confirmed_at: "2026-01-01T00:00:00Z" }

/** Nonce declarado por una política, como lo lee Next. */
function nonceOf(csp: string | null): string | null {
  const directive = csp
    ?.split(";")
    .map((d) => d.trim())
    .find((d) => d.startsWith("script-src"))
  const match = directive?.match(/'nonce-([^']+)'/)
  return match ? match[1] : null
}

beforeEach(() => {
  resetHarness()
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.supabase.co")
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY", "anon-key")
})

describe("updateSession — /api/auth/* no toca al proveedor", () => {
  it.each(["/api/auth/token", "/api/auth/status"])(
    "%s no dispara getUser(): la renovación queda en el manejador, donde está el single-flight",
    async (pathname) => {
      harness.user = CONFIRMED

      const response = await updateSession(
        buildRequest(pathname, { "sb-project-auth-token": "base64-viva" }),
      )

      expect(harness.events).not.toContain("getUser")
      expect(isRedirect(response)).toBe(false)
    },
  )

  it("el resto de /api/** conserva su camino (el cortocircuito es angosto)", async () => {
    harness.user = CONFIRMED

    await updateSession(buildRequest("/api/ai/copilot"))

    expect(harness.events).toContain("getUser")
  })

  it("y una página sigue validando la sesión contra el proveedor", async () => {
    harness.user = CONFIRMED

    await updateSession(
      buildRequest("/caja", { "auth:last-activity": String(Date.now()) }),
    )

    expect(harness.events).toContain("getUser")
  })

  it("la respuesta cortocircuitada conserva la CSP y el nonce en los dos encabezados", async () => {
    harness.user = CONFIRMED

    const response = await updateSession(buildRequest("/api/auth/token"))

    const responseCsp = response.headers.get("content-security-policy")
    const requestCsp = response.headers.get("x-middleware-request-content-security-policy")

    expect(nonceOf(responseCsp)).toBeTruthy()
    expect(requestCsp).toBe(responseCsp)
    expect(response.headers.get("x-middleware-request-x-nonce")).toBe(nonceOf(responseCsp))
    // El resto de los encabezados de seguridad tampoco se pierde.
    expect(response.headers.get("X-Content-Type-Options")).toBe("nosniff")
  })

  it("una cookie de sesión ilegible en /api/auth/* no explota: el manejador la trata como ausente", async () => {
    // El `try` del manejador ya cubre este caso (`api/auth/token/route.ts:171-178`),
    // pero antes del cortocircuito la excepción salía del `getUser()` del
    // middleware, que corre PRIMERO y no la atajaba.
    harness.user = null
    harness.getUserThrows = true

    const response = await updateSession(
      buildRequest("/api/auth/token", { "sb-project-auth-token": "no-es-base64url-válido" }),
    )

    expect(response.status).toBe(200)
    expect(harness.events).not.toContain("getUser")
  })
})

/**
 * auth-hardening-jwt-cookies — Parte C, D1/D2. Revisión adversarial pre-merge
 * (MAJOR: los cuatro flujos por email pasaron a generar el verificador PKCE en el
 * servidor y no tenían verificación en ningún nivel).
 *
 * `signUp`, `signInWithOtp`, `resetPasswordForEmail` y `updateUser({email})` corren
 * ahora en Server Actions, así que el `sb-…-auth-token-code-verifier` lo escribe
 * `cookieStore.set` dentro de `lib/supabase/server.ts:18-28`, **cuyo `catch {}` se
 * come cualquier fallo de escritura en silencio**. Si el verificador no persiste,
 * `exchangeCodeForSession` falla y TODO enlace por email cae en
 * `/auth/login?error=auth_callback_error`: el 100% de los registros nuevos y de las
 * recuperaciones de contraseña.
 *
 * Cobertura antes de este spec: los tests de las acciones doblan el cliente de
 * servidor (no observan cookies), no había ningún E2E de estas pantallas, y el humo
 * del grupo 22 cubrió login con contraseña y los estados visuales. La revisión lo
 * llamó "barato y local", y lo es: el stack de Supabase en docker trae el servidor
 * de correo en `http://127.0.0.1:54324`.
 *
 * Lo que este spec fija, de punta a punta y contra el stack real:
 *
 *  1. el pedido de recuperación escribe el verificador PKCE **con `HttpOnly`**, y
 *     `document.cookie` no lo ve;
 *  2. el enlace del correo, intercambiado en `/auth/callback`, **encuentra** ese
 *     verificador y produce una sesión — es decir, el `catch {}` no se comió nada;
 *  3. la sesión aterriza en `/auth/reset-password` (no en
 *     `?error=auth_callback_error`) y su cookie también es `HttpOnly`.
 *
 * NO cambia la contraseña del usuario QA: las demás suites dependen de ella. Lo que
 * importaba verificar es el intercambio del código, que es lo que el `catch {}`
 * podía romper en silencio.
 */
import { test, expect, type APIRequestContext } from '@playwright/test'

/** Servidor de correo del stack local de Supabase (Mailpit). */
const MAIL_API = 'http://127.0.0.1:54324/api/v1'

interface MailpitSummary {
  ID: string
  Subject: string
  Created: string
  To: Array<{ Address: string }>
}

async function messagesFor(
  request: APIRequestContext,
  email: string,
  since: number,
): Promise<MailpitSummary[]> {
  const response = await request.get(`${MAIL_API}/messages?limit=50`)
  expect(response.ok(), 'el servidor de correo local no respondió').toBeTruthy()
  const body = (await response.json()) as { messages?: MailpitSummary[] }
  return (body.messages ?? []).filter(
    (message) =>
      message.To?.some((to) => to.Address.toLowerCase() === email.toLowerCase()) &&
      Date.parse(message.Created) >= since,
  )
}

/** Cuerpo de texto de un mensaje. */
async function messageText(request: APIRequestContext, id: string): Promise<string> {
  const response = await request.get(`${MAIL_API}/message/${id}`)
  expect(response.ok()).toBeTruthy()
  const body = (await response.json()) as { Text?: string; HTML?: string }
  return `${body.Text ?? ''}\n${body.HTML ?? ''}`
}

/** El enlace `/auth/v1/verify?...` que trae el correo. */
function verifyLinkOf(text: string): string {
  const match = text.match(/https?:\/\/[^\s"')]+\/auth\/v1\/verify\?[^\s"')]+/)
  expect(match, `el correo no trae enlace de verificación:\n${text.slice(0, 600)}`).not.toBeNull()
  return match![0].replace(/&amp;/g, '&')
}

test.describe('Auth — flujos por email (verificador PKCE en el servidor)', () => {
  // Sin sesión: `/auth/*` con sesión confirmada rebota al dashboard.
  test.use({ storageState: { cookies: [], origins: [] } })

  test('recuperación de contraseña: verificador httpOnly, enlace del correo y sesión', async ({
    page,
    context,
    request,
  }) => {
    const email = process.env.QA_TEST_USER_EMAIL!
    const startedAt = Date.now() - 1_000

    // ── 1. La pantalla pide el enlace (captcha stubeado por NEXT_PUBLIC_PLAYWRIGHT_LOCAL)
    await page.goto('/auth/forgot-password')
    await page.locator('#email').fill(email)
    await page.getByRole('button', { name: /enviar enlace de recuperación/i }).click()
    await expect(page.getByText(/revisá tu bandeja de entrada/i)).toBeVisible({ timeout: 30_000 })

    // ── 2. El verificador PKCE existe, es httpOnly y JavaScript no lo ve ──────
    const verifier = (await context.cookies()).find((cookie) =>
      cookie.name.includes('code-verifier'),
    )
    expect(
      verifier,
      'la Server Action no dejó el verificador PKCE: el `catch {}` de lib/supabase/server.ts se comió la escritura',
    ).toBeDefined()
    expect(verifier!.httpOnly).toBe(true)
    expect(verifier!.path).toBe('/')
    expect(verifier!.sameSite).toBe('Lax')

    const readableByJs = await page.evaluate(() => document.cookie)
    expect(readableByJs).not.toContain('code-verifier')

    // ── 3. El correo llega y trae el enlace de verificación ──────────────────
    let recovery: MailpitSummary | undefined
    await expect
      .poll(
        async () => {
          const found = await messagesFor(request, email, startedAt)
          recovery = found.find((message) => /reset|recuper|password/i.test(message.Subject))
          return recovery ? 1 : 0
        },
        { timeout: 30_000, message: 'no llegó el correo de recuperación al servidor local' },
      )
      .toBe(1)

    const verifyUrl = verifyLinkOf(await messageText(request, recovery!.ID))
    expect(verifyUrl).toContain('type=recovery')

    // ── 4. El proveedor canjea el token del enlace por un `code` ─────────────
    //
    // Se sigue el redirect a mano y se toma SÓLO el `code`: el `redirect_to` del
    // correo depende de la allow-list del proyecto local y no es lo que este spec
    // verifica — lo que se verifica es que nuestro `/auth/callback` sepa
    // intercambiarlo con el verificador que quedó en la cookie httpOnly.
    const verifyResponse = await request.get(verifyUrl, { maxRedirects: 0 })
    const location = verifyResponse.headers()['location']
    expect(location, 'el proveedor no redirigió con un código').toBeTruthy()
    const code = new URL(location).searchParams.get('code')
    expect(code, `el redirect del proveedor no trae code: ${location}`).toBeTruthy()

    // ── 5. El intercambio en el servidor produce sesión y aterriza en la pantalla
    await page.goto(`/auth/callback?code=${code}&next=%2Fauth%2Freset-password`)

    await expect(page).toHaveURL(/\/auth\/reset-password/, { timeout: 30_000 })
    await expect(page).not.toHaveURL(/auth_callback_error/)

    const session = (await context.cookies()).find(
      (cookie) => cookie.name.startsWith('sb-') && !cookie.name.includes('code-verifier'),
    )
    expect(session, 'el intercambio del código no dejó sesión').toBeDefined()
    expect(session!.httpOnly).toBe(true)

    const readableAfter = await page.evaluate(() => document.cookie)
    expect(readableAfter).not.toContain('auth-token')

    // Y la pantalla de cambio de contraseña está operativa (no se envía: las demás
    // suites dependen de la contraseña de este usuario).
    await expect(page.getByRole('button', { name: /actualizar contraseña/i })).toBeVisible()
  })

  test('el enlace mágico también deja el verificador en una cookie httpOnly', async ({
    page,
    context,
    request,
  }) => {
    // Segundo caso de la misma familia (`signInWithOtp`), para que el flujo por
    // email no quede fijado por un único camino.
    const email = process.env.QA_LOGOUT_USER_EMAIL!
    const startedAt = Date.now() - 1_000

    await page.goto('/auth/login')
    await page.getByRole('button', { name: /entrar con enlace mágico/i }).click()
    await page.locator('#magic-email').fill(email)
    await page.getByRole('button', { name: /^enviar enlace mágico$/i }).click()
    await expect(page.getByText(/¡enlace enviado!/i)).toBeVisible({ timeout: 30_000 })

    await expect
      .poll(
        async () => (await messagesFor(request, email, startedAt)).length,
        { timeout: 30_000, message: 'no llegó el correo del enlace mágico' },
      )
      .toBeGreaterThan(0)

    const verifier = (await context.cookies()).find((cookie) =>
      cookie.name.includes('code-verifier'),
    )
    expect(verifier).toBeDefined()
    expect(verifier!.httpOnly).toBe(true)
    expect(await page.evaluate(() => document.cookie)).not.toContain('code-verifier')
  })
})

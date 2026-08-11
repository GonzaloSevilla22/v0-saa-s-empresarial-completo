import { test, expect } from '@playwright/test'

/**
 * Camino híbrido completo (DEC-16): Next → FastAPI local → asyncpg → Postgres
 * local con la cadena de migraciones entera.
 *
 * /productos consume GET /products vía pythonClient con el Bearer JWT del
 * usuario QA. Un response ok acá prueba de una vez: backend arriba, JWT
 * emitido por el Supabase local validado contra su JWT_SECRET, CORS hacia
 * localhost:3000, y la query del repositorio contra el schema recién migrado.
 * (El usuario QA nace sin productos — lista vacía es un 200 válido.)
 */
test('productos consume el backend FastAPI (camino híbrido completo)', async ({ page }) => {
  const backendUrl = process.env.NEXT_PUBLIC_BACKEND_URL_LOCAL ?? 'http://localhost:8000'

  const backendResponse = page.waitForResponse(
    (resp) =>
      resp.url().startsWith(backendUrl) &&
      resp.request().method() === 'GET' &&
      resp.ok(),
    { timeout: 60_000 },
  )

  await page.goto('/productos')
  await backendResponse

  await expect(
    page.getByRole('button', { name: /nuevo producto/i }).first(),
  ).toBeVisible({ timeout: 30_000 })
})

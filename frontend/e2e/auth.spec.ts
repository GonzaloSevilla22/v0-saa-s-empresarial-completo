import { test, expect } from '@playwright/test'

test.describe('Auth — sin sesion', () => {
  test.use({ storageState: { cookies: [], origins: [] } })

  test('la pagina inicial carga', async ({ page }) => {
    await page.goto('/')
    await expect(page).not.toHaveURL(/error/)
  })

  test('login invalido muestra error', async ({ page }) => {
    await page.goto('/auth/login')
    await page.getByTestId('login-email').fill('qa.e2e@local.test')
    await page.getByTestId('login-password').fill('password-incorrecta')
    await page.getByTestId('login-submit').click()

    await expect(page.getByText(/invalid login credentials|credenciales/i)).toBeVisible({ timeout: 10_000 })
    await expect(page).toHaveURL(/\/auth\/login/)
  })

  test('login valido redirige a dashboard', async ({ page }) => {
    const email = process.env.QA_TEST_USER_EMAIL!
    const password = process.env.QA_TEST_USER_PASSWORD!

    await page.goto('/auth/login')
    await page.getByTestId('login-email').fill(email)
    await page.getByTestId('login-password').fill(password)
    await page.getByTestId('login-submit').click()

    // Timeout generoso: ver auth.setup.ts (compilacion en frio de /dashboard).
    await expect(page).toHaveURL(/\/dashboard/, { timeout: 60_000 })
  })

  test('ruta protegida sin sesion redirige a login', async ({ page }) => {
    await page.goto('/dashboard')
    await expect(page).toHaveURL(/\/auth\/login/)
  })
})

test.describe('Auth — con sesion', () => {
  // auth-hardening-jwt-cookies (D6): `logout()` pasa a `signOut({ scope:
  // 'local' })`, asi que YA NO revoca los refresh tokens de las demas
  // sesiones. El comentario anterior describia el default de la libreria
  // (`signOut()` pelado es global) y dejo de ser cierto para este boton.
  // El usuario QA dedicado (QA_LOGOUT_USER_*) y el storageState vacio se
  // conservan igual: aislan este spec de los demas sin costo, y protegen
  // contra que alguien vuelva a ampliar el alcance sin darse cuenta.
  test.use({ storageState: { cookies: [], origins: [] } })

  test('logout cierra sesion', async ({ page }) => {
    const email = process.env.QA_LOGOUT_USER_EMAIL!
    const password = process.env.QA_LOGOUT_USER_PASSWORD!

    await page.goto('/auth/login')
    await page.getByTestId('login-email').fill(email)
    await page.getByTestId('login-password').fill(password)
    await page.getByTestId('login-submit').click()
    // Timeout generoso: ver auth.setup.ts (compilacion en frio de /dashboard).
    await expect(page).toHaveURL(/\/dashboard/, { timeout: 60_000 })

    await page.getByTestId('logout-button').click()

    await expect(page).toHaveURL(/\/auth\/login|\/$/, { timeout: 10_000 })
  })
})

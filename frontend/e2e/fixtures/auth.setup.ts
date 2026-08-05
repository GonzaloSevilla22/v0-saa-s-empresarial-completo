import { test as setup, expect } from '@playwright/test'

const authFile = './e2e/.auth/user.json'

setup('authenticate', async ({ page }) => {
  const email = process.env.QA_TEST_USER_EMAIL
  const password = process.env.QA_TEST_USER_PASSWORD
  if (!email || !password) {
    throw new Error('[auth.setup] QA_TEST_USER_EMAIL y QA_TEST_USER_PASSWORD son requeridas (.env.test.local).')
  }

  await page.goto('/auth/login')
  await page.getByTestId('login-email').fill(email)
  await page.getByTestId('login-password').fill(password)
  await page.getByTestId('login-submit').click()

  // Timeout MUY generoso: esta es la unica compilacion en frio de /dashboard
  // (ruta pesada: sidebar + KPIs + charts + escena 3D) bajo Turbopack. En este
  // entorno (WSL2 + filesystem de Windows via /mnt/c/) /auth/login sola tardo
  // ~25s en compilar; /dashboard es varias veces mas pesada y >60s no alcanzo.
  // Una vez compilada, las navegaciones posteriores a /dashboard son rapidas.
  await expect(page).toHaveURL(/\/dashboard/, { timeout: 150_000 })

  await page.context().storageState({ path: authFile })
})

import { test, expect } from '@playwright/test'

test('dashboard autenticado carga y muestra KPIs', async ({ page }) => {
  await page.goto('/dashboard')
  await expect(page).toHaveURL(/\/dashboard/)
  await expect(page.getByTestId('kpi-summary-block')).toBeVisible({ timeout: 15_000 })
})

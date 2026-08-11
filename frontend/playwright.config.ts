import { defineConfig, devices } from '@playwright/test'
import { existsSync } from 'node:fs'
import { loadEnvFile } from 'node:process'

const localEnvFile = '.env.test.local'
if (existsSync(localEnvFile)) {
  loadEnvFile(localEnvFile)
}

export default defineConfig({
  testDir: './e2e',
  fullyParallel: false,
  retries: 0,
  workers: 1,
  // 90s no alcanza en este entorno cuando dos rutas en frio (ej. /auth/login
  // Y /dashboard) se compilan dentro del mismo test — ver auth.setup.ts.
  // 300s = margen para compilar /auth/login (~25s) + /dashboard (>60s) + acciones.
  timeout: 300_000,
  reporter: [['html', { open: 'never' }]],
  globalSetup: './e2e/fixtures/global-setup.ts',
  use: {
    baseURL: process.env.PLAYWRIGHT_BASE_URL ?? 'http://localhost:3000',
    navigationTimeout: 60_000,
    // 45s (no 15s): el gate de arranque del auth-context (auth-context.tsx
    // muestra "Loading..." hasta resolver el chequeo inicial de sesion) puede
    // tardar >15s en el primer boot en frio del cliente en este entorno. Es un
    // techo, no una espera fija — las acciones en paginas ya calientes vuelven
    // al instante.
    actionTimeout: 45_000,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  projects: [
    { name: 'setup', testMatch: /auth\.setup\.ts/ },
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'], storageState: './e2e/.auth/user.json' },
      dependencies: ['setup'],
      testIgnore: /auth\.setup\.ts/,
    },
  ],
  webServer: {
    command: 'pnpm dev',
    url: 'http://localhost:3000',
    reuseExistingServer: true,
    timeout: 240_000,
    stdout: 'pipe',
    stderr: 'pipe',
    env: {
      NODE_ENV: 'development',
      NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL_LOCAL ?? '',
      NEXT_PUBLIC_SUPABASE_ANON_KEY: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY_LOCAL ?? '',
      NEXT_PUBLIC_BACKEND_URL: process.env.NEXT_PUBLIC_BACKEND_URL_LOCAL ?? 'http://localhost:8000',
      NEXT_PUBLIC_PLAYWRIGHT_LOCAL: 'true',
    },
  },
})

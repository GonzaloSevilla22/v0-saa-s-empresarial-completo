import { configDefaults, defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'
import path from 'path'

export default defineConfig({
  plugins: [react()],
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['__tests__/setup.ts'],
    // Los specs de Playwright (e2e/) no son tests de vitest.
    exclude: [...configDefaults.exclude, 'e2e/**'],
    maxWorkers: 8,
    // Los runners de CI (2 cores, caches fríos) montan componentes pesados
    // mucho más lento que una máquina de dev: con el default de 5s un test
    // puede morir por timeout sin estar colgado y su continuación zombie
    // contamina el DOM de los tests siguientes (clase H-3, ver
    // __tests__/components/product-catalog-search-collapse.test.tsx).
    // 20s sigue atrapando hangs reales.
    testTimeout: 20_000,
  },
  resolve: {
    alias: {
      '@': path.resolve(__dirname, '.'),
    },
  },
})

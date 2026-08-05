import { runEnvGuard } from './env-guard'
import http from 'http'

function warmRoute(path: string, baseURL: string): Promise<void> {
  return new Promise((resolve) => {
    const url = new URL(path, baseURL)
    http.get(url.toString(), (res) => {
      res.resume()
      res.on('end', resolve)
    }).on('error', () => resolve()) // best-effort; test will surface real errors
  })
}

export default async function globalSetup() {
  runEnvGuard()

  const baseURL = process.env.PLAYWRIGHT_BASE_URL ?? 'http://localhost:3000'
  // Pre-compile lazy Turbopack routes so tests don't time out on first navigation
  await Promise.all([
    warmRoute('/', baseURL),
    warmRoute('/auth/login', baseURL),
  ])
}

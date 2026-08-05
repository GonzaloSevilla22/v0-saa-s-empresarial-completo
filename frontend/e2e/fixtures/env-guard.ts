const LOCAL_HOSTS = ['localhost', '127.0.0.1']

const FORBIDDEN_PATTERNS = ['supabase.co', 'vercel.app', 'render.com', 'mercadopago', 'afip.gov.ar', 'wsfe.afip']

function assertLocalUrl(name: string, value: string | undefined) {
  if (!value) {
    throw new Error(`[env-guard] ${name} no esta definida.`)
  }
  let hostname: string
  try {
    hostname = new URL(value).hostname
  } catch {
    throw new Error(`[env-guard] ${name} no es una URL valida.`)
  }
  if (!LOCAL_HOSTS.includes(hostname)) {
    throw new Error(`[env-guard] ${name} no apunta a localhost/127.0.0.1. Abortando para proteger produccion.`)
  }
}

function assertPresent(name: string, value: string | undefined) {
  if (!value) {
    throw new Error(`[env-guard] ${name} no esta definida.`)
  }
}

export function runEnvGuard() {
  assertLocalUrl('PLAYWRIGHT_BASE_URL', process.env.PLAYWRIGHT_BASE_URL ?? 'http://localhost:3000')
  assertLocalUrl('NEXT_PUBLIC_SUPABASE_URL_LOCAL', process.env.NEXT_PUBLIC_SUPABASE_URL_LOCAL)
  assertLocalUrl('NEXT_PUBLIC_BACKEND_URL_LOCAL', process.env.NEXT_PUBLIC_BACKEND_URL_LOCAL)
  assertPresent('NEXT_PUBLIC_SUPABASE_ANON_KEY_LOCAL', process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY_LOCAL)
  assertPresent('QA_TEST_USER_EMAIL', process.env.QA_TEST_USER_EMAIL)
  assertPresent('QA_TEST_USER_PASSWORD', process.env.QA_TEST_USER_PASSWORD)
  assertPresent('QA_LOGOUT_USER_EMAIL', process.env.QA_LOGOUT_USER_EMAIL)
  assertPresent('QA_LOGOUT_USER_PASSWORD', process.env.QA_LOGOUT_USER_PASSWORD)

  const relevantValues = Object.entries(process.env)
    .filter(([key]) => key.startsWith('NEXT_PUBLIC_') || key.includes('SUPABASE') || key.includes('BACKEND') || key.includes('MERCADOPAGO') || key.includes('WSFE'))
    .map(([, value]) => value ?? '')

  for (const value of relevantValues) {
    const lower = value.toLowerCase()
    const match = FORBIDDEN_PATTERNS.find((pattern) => lower.includes(pattern))
    if (match) {
      throw new Error(`[env-guard] Se detecto "${match}" en una variable de entorno. Abortando — no se permite apuntar a servicios reales en tests E2E.`)
    }
  }
}

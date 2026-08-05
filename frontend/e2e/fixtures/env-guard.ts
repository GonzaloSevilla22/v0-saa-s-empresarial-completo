const LOCAL_HOSTS = ['localhost', '127.0.0.1']

const FORBIDDEN_PATTERNS = ['supabase.co', 'vercel.app', 'render.com', 'mercadopago', 'afip.gov.ar', 'wsfe.afip']

function assertLocalUrl(name: string, value: string | undefined) {
  if (!value) {
    throw new Error(`[env-guard] ${name} no esta definida.`)
  }
  if (!LOCAL_HOSTS.some((host) => value.includes(host))) {
    throw new Error(`[env-guard] ${name}="${value}" no apunta a localhost/127.0.0.1. Abortando para proteger produccion.`)
  }
}

export function runEnvGuard() {
  assertLocalUrl('NEXT_PUBLIC_SUPABASE_URL_LOCAL', process.env.NEXT_PUBLIC_SUPABASE_URL_LOCAL)
  assertLocalUrl('NEXT_PUBLIC_BACKEND_URL_LOCAL', process.env.NEXT_PUBLIC_BACKEND_URL_LOCAL)

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

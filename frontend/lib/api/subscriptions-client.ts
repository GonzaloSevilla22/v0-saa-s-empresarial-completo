import { createClient } from "@/lib/supabase/client"

// mp-real-subscriptions (D2bis, PR4) — cliente del flujo de suscripciones
// reales del backend. `billing_subscriptions_enabled` es una palanca de
// SOLO backend (default OFF, ver backend/core/config.py) — el frontend no
// duplica esa palanca con una variable propia. En su lugar, intenta el
// endpoint nuevo y distingue el 503 explícito ("Suscripciones no
// habilitadas todavía") de cualquier otro resultado: el caller decide si
// cae al flujo legacy de pago único (task 8.1/8.2, no-regresión con la
// palanca apagada — estado actual de prod).

const BACKEND_URL = process.env.NEXT_PUBLIC_BACKEND_URL

export type SubscriptionPlan = "inicial" | "avanzado" | "pro"

export interface SubscriptionCreateResult {
  init_point: string
  intent_id: string
  plan: string
  expires_at: string
}

export interface SubscriptionCancelResult {
  ok: boolean
  plan_expires_at: string | null
}

export interface SubscriptionStatus {
  id: string
  plan: string
  status: string
  next_payment_date: string | null
  amount: number | null
  currency: string
  retry_state: string
}

/** Resultado discriminado: la palanca puede estar apagada (503) sin que eso sea un error real. */
export type SubscriptionsFeatureResult<T> =
  | { enabled: true; data: T }
  | { enabled: false }

async function authHeaders(): Promise<HeadersInit> {
  const supabase = createClient()
  const {
    data: { session },
  } = await supabase.auth.getSession()
  const token = session?.access_token ?? ""
  return {
    "Content-Type": "application/json",
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
  }
}

async function parseErrorDetail(response: Response): Promise<string> {
  try {
    const body = (await response.json()) as { detail?: string }
    return body.detail ?? response.statusText
  } catch {
    return response.statusText
  }
}

/**
 * planes-suscribirse-plan-vigente (D8): lanzado por `createSubscription`
 * cuando el backend rechaza con 409 por ya existir una suscripción viva
 * para la cuenta (carrera: otra pestaña completó un checkout mientras esta
 * pantalla seguía abierta). Permite al caller (`PlanComparison.handleSelect`)
 * distinguir este caso puntual del resto de errores sin parsear el
 * `detail` crudo del backend — sigue siendo un `Error` (mismo `message`),
 * así que cualquier manejo genérico existente no se ve afectado.
 */
export class SubscriptionConflictError extends Error {
  constructor(detail: string) {
    super(detail)
    this.name = "SubscriptionConflictError"
  }
}

export async function createSubscription(
  plan: SubscriptionPlan,
): Promise<SubscriptionsFeatureResult<SubscriptionCreateResult>> {
  if (!BACKEND_URL) {
    return { enabled: false }
  }
  const headers = await authHeaders()
  const response = await fetch(`${BACKEND_URL}/payments/subscriptions`, {
    method: "POST",
    headers,
    body: JSON.stringify({ plan }),
  })

  if (response.status === 503) {
    return { enabled: false }
  }
  if (!response.ok) {
    const detail = await parseErrorDetail(response)
    if (response.status === 409) {
      throw new SubscriptionConflictError(detail)
    }
    throw new Error(detail)
  }
  const data = (await response.json()) as SubscriptionCreateResult
  return { enabled: true, data }
}

export async function cancelSubscription(): Promise<
  SubscriptionsFeatureResult<SubscriptionCancelResult>
> {
  if (!BACKEND_URL) {
    return { enabled: false }
  }
  const headers = await authHeaders()
  const response = await fetch(`${BACKEND_URL}/payments/subscriptions`, {
    method: "DELETE",
    headers,
  })

  if (response.status === 503) {
    return { enabled: false }
  }
  if (!response.ok) {
    throw new Error(await parseErrorDetail(response))
  }
  const data = (await response.json()) as SubscriptionCancelResult
  return { enabled: true, data }
}

export async function getSubscriptionStatus(): Promise<
  SubscriptionsFeatureResult<SubscriptionStatus | null>
> {
  if (!BACKEND_URL) {
    return { enabled: false }
  }
  const headers = await authHeaders()
  const response = await fetch(`${BACKEND_URL}/payments/subscriptions/status`, {
    method: "GET",
    headers,
  })

  if (response.status === 503) {
    return { enabled: false }
  }
  if (response.status === 404) {
    return { enabled: true, data: null }
  }
  if (!response.ok) {
    throw new Error(await parseErrorDetail(response))
  }
  const data = (await response.json()) as SubscriptionStatus
  return { enabled: true, data }
}

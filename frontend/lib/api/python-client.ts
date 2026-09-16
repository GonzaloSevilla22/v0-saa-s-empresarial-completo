import { getAuthHeaders, handleUnauthorized, tokenFromHeaders } from "@/lib/api/auth-headers";

const BACKEND_URL = process.env.NEXT_PUBLIC_BACKEND_URL;

if (!BACKEND_URL) {
  throw new Error(
    "[python-client] NEXT_PUBLIC_BACKEND_URL is not defined. " +
      "Set it in your .env.local (e.g. NEXT_PUBLIC_BACKEND_URL=http://localhost:8000)."
  );
}

const JSON_HEADERS = { "Content-Type": "application/json" } as const;

/**
 * auth-hardening-jwt-cookies (D21): los encabezados de auth los arma
 * `lib/api/auth-headers.ts`, que es el único sitio que compone el Bearer y el
 * que decide omitirlo cuando no hay token. El comentario que había acá decía
 * que `getSession()` "reads from local storage": es falso — lee las cookies
 * `sb-*`, chunkeadas a 3180 bytes por `@supabase/ssr`.
 */
function jsonAuthHeaders(extra?: Record<string, string>): Promise<Record<string, string>> {
  return getAuthHeaders({ ...JSON_HEADERS, ...(extra ?? {}) });
}

/**
 * auth-hardening-jwt-cookies (D7): antes se lanzaba "recargá la página". Esa
 * recomendación delegaba la renovación en un redirect del middleware que en las
 * 12 rutas de F1 nunca ocurría.
 *
 * Revisión adversarial (MINOR 1 de seguridad): los cuatro desenlaces tienen
 * mensajes distintos porque `getSession()` **auto-refresca**, así que el caso más
 * frecuente —"el token venció mientras la pantalla estaba abierta"— devuelve un
 * token NUEVO y caía en el mensaje de permisos: un veredicto de autorización
 * para un problema de frescura ya resuelto, y sin insinuar ninguna salida.
 */
const UNAUTHORIZED_MESSAGES = {
  navigated: "Tu sesión venció. Te llevamos al inicio de sesión.",
  "session-renewed": "Tu sesión se renovó. Reintentá la operación.",
  "session-active": "No autorizado para esta operación.",
  "session-unknown": "No se pudo autorizar la operación. Reintentá.",
} as const;

async function handleResponse<T>(response: Response, sentToken?: string | null): Promise<T> {
  if (response.status === 401) {
    const outcome = await handleUnauthorized(sentToken);
    throw new Error(UNAUTHORIZED_MESSAGES[outcome]);
  }
  if (!response.ok) {
    const body = await response.json().catch(() => ({ detail: response.statusText }));
    throw new Error(body.detail ?? response.statusText);
  }
  // 204 No Content (p. ej. DELETE) no trae body: parsear con response.json()
  // tiraría "Unexpected end of JSON input". Devolvemos undefined.
  if (response.status === 204) {
    return undefined as T;
  }
  return response.json() as Promise<T>;
}

export const pythonClient = {
  async get<T>(path: string): Promise<T> {
    const headers = await jsonAuthHeaders();
    const response = await fetch(`${BACKEND_URL as string}${path}`, { method: "GET", headers });
    return handleResponse<T>(response, tokenFromHeaders(headers));
  },

  async post<T>(path: string, body: unknown, extraHeaders?: Record<string, string>): Promise<T> {
    // v3-api-standards §6.2: extraHeaders permite enviar Idempotency-Key sin
    // tocar la firma de las llamadas existentes (parámetro opcional).
    // auth-hardening-jwt-cookies (14.8): los de auth se aplican DESPUÉS de
    // `extraHeaders` — antes era al revés y un caller podía sobrescribir
    // `Authorization`. El orden lo garantiza `getAuthHeaders()`, no este sitio.
    const headers = await jsonAuthHeaders(extraHeaders);
    const response = await fetch(`${BACKEND_URL as string}${path}`, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    });
    return handleResponse<T>(response, tokenFromHeaders(headers));
  },

  async put<T>(path: string, body: unknown): Promise<T> {
    const headers = await jsonAuthHeaders();
    const response = await fetch(`${BACKEND_URL as string}${path}`, {
      method: "PUT",
      headers,
      body: JSON.stringify(body),
    });
    return handleResponse<T>(response, tokenFromHeaders(headers));
  },

  async patch<T>(path: string, body: unknown): Promise<T> {
    const headers = await jsonAuthHeaders();
    const response = await fetch(`${BACKEND_URL as string}${path}`, {
      method: "PATCH",
      headers,
      body: JSON.stringify(body),
    });
    return handleResponse<T>(response, tokenFromHeaders(headers));
  },

  async delete<T>(path: string, body?: unknown): Promise<T> {
    // cobranzas-reverso (task 12.1): DELETE con body opcional — la
    // anulación de un cobro/pago acepta un motivo por body (D9: sin
    // Idempotency-Key). `body` es opcional para no romper ninguno de los
    // llamadores existentes, que nunca lo pasan.
    const headers = await jsonAuthHeaders();
    const response = await fetch(`${BACKEND_URL as string}${path}`, {
      method: "DELETE",
      headers,
      ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
    });
    return handleResponse<T>(response, tokenFromHeaders(headers));
  },
};

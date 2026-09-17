/**
 * client.ts — el cliente de Supabase del navegador.
 *
 * auth-hardening-jwt-cookies (Parte C, D1, tasks 19.6 y 19.9). Deja de ser un
 * `createBrowserClient`, que leía la sesión de `document.cookie`, y pasa a tomar
 * el token de un callback:
 *
 *     createClient(url, anonKey, { accessToken: () => getAccessToken() })
 *
 * Soportado por `@supabase/supabase-js` 2.104.1: el callback alimenta REST,
 * Storage y Functions (`index.mjs:107-118`, `:392`, `:527`) y Realtime lo recibe
 * como `{ accessToken }` (`:395`). El token vive sólo en memoria
 * (`lib/auth/access-token-store.ts`) y sale de `GET /api/auth/token`.
 *
 * ── Dos consecuencias que hay que conocer antes de tocar este archivo ───────
 *
 * 1. **`supabase.auth` deja de existir.** Con `accessToken` configurado,
 *    cualquier acceso a `supabase.auth.*` **lanza** (`index.mjs:389`) y
 *    `_listenForAuthEvents()` no se instala (`:407`). Las operaciones de sesión
 *    viven en `app/auth/actions.ts` (servidor); la identidad, en `useAuth()` para
 *    componentes y en `getSessionUser()` para módulos sin hooks. El candado que
 *    lo mantiene así es `__tests__/lib/no-browser-auth-calls.test.ts`.
 *
 * 2. **Realtime queda pinneado al token del arranque si nadie lo despinnea.**
 *    `supabase-js` llama `realtime.setAuth(token)` con un token **explícito** al
 *    construir (`index.mjs:398`), y con un token explícito *"the `accessToken`
 *    callback will not be invoked until `setAuth()` is called without arguments"*
 *    (`RealtimeClient.js:330-339`). Por eso este módulo se suscribe al store y
 *    llama `realtime.setAuth()` **SIN argumentos** en cada renovación. Con
 *    argumento, el pin se perpetúa y `use-notifications` + `FiscalDocumentBadge`
 *    se quedan mudos al primer vencimiento **sin ningún error visible**. El
 *    cableado vive acá, una vez, y no copiado en cada hook que abre un canal.
 */
import { createClient as createSupabaseClient } from "@supabase/supabase-js"
import { getAccessToken, subscribeToAccessToken } from "@/lib/auth/access-token-store"

/**
 * Cliente único de la pestaña.
 *
 * `createBrowserClient` cacheaba el cliente cuando detectaba un navegador
 * (`createBrowserClient.js:8-14`); perder esa propiedad al cambiar de constructor
 * abriría una conexión de Realtime por cada `createClient()` del árbol de
 * componentes. Sólo se cachea en el navegador: en el render del servidor no hay
 * pestaña a la que pertenecer, y un cliente cacheado en un proceso compartido
 * sería estado de un usuario visible para el siguiente.
 */
function buildClient() {
  return createSupabaseClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      // Resuelve a `null` sin lanzar cuando no hay sesión, de modo que
      // `fetchWithAuth` caiga a la anon key (`index.mjs:112`) y una página
      // pública siga renderizando para un visitante anónimo.
      accessToken: () => getAccessToken(),
    },
  )
}

/**
 * El tipo sale de `buildClient` y no de `ReturnType<typeof createSupabaseClient>`:
 * el segundo evalúa los genéricos con sus **defaults** (`schema: never`) en vez de
 * con los que el constructor infiere de esta llamada, y el cliente concreto
 * (`schema: "public"`) no es asignable a eso.
 */
let cachedBrowserClient: ReturnType<typeof buildClient> | null = null

export function createClient() {
  if (cachedBrowserClient) return cachedBrowserClient

  const client = buildClient()

  if (typeof window !== "undefined") {
    // SIN argumentos: es lo que despinnea el canal y devuelve el control al
    // callback. Ver la consecuencia 2 del encabezado.
    subscribeToAccessToken(() => {
      void client.realtime.setAuth()
    })
    cachedBrowserClient = client
  }

  return client
}

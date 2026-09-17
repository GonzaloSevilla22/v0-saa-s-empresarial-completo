/**
 * auth-hardening-jwt-cookies — Parte C, D1, tasks 19.5 y 19.5b.
 *
 * El access token que `GET /api/auth/token` entrega vive **sólo en memoria del
 * módulo**. Si se escribiera en una cookie, en `localStorage` o en
 * `sessionStorage`, el change no habría movido nada: seguiría habiendo una
 * credencial legible por cualquier script de la página. La diferencia es que ésta
 * dura una hora y la que se protege dura 400 días — pero guardarla anularía el
 * motivo por el que existe el manejador.
 *
 * Cada caso recarga el módulo (`vi.resetModules()` + `import()`) porque lo que se
 * está probando **es** el estado de módulo: un caché compartido entre casos
 * ocultaría justamente los errores de esa capa.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"

type Store = typeof import("@/lib/auth/access-token-store")

const TOKEN = "access-token-1"
const NEXT_TOKEN = "access-token-2"
const USER = { id: "11111111-1111-4111-8111-111111111111", email: "duenio@test.local" }

/** Segundos epoch a los que vence un token que dura `seconds` más. */
const expiresIn = (seconds: number) => Math.floor(Date.now() / 1000) + seconds

let fetchMock: ReturnType<typeof vi.fn>

function respondWith(...payloads: Record<string, unknown>[]): void {
  for (const payload of payloads) {
    fetchMock.mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: async () => payload,
    } as unknown as Response)
  }
}

const withSession = (token = TOKEN, seconds = 3600) => ({
  access_token: token,
  expires_at: expiresIn(seconds),
  user: USER,
})

const withoutSession = () => ({ access_token: null, expires_at: null, user: null })

async function loadStore(): Promise<Store> {
  vi.resetModules()
  return (await import("@/lib/auth/access-token-store")) as Store
}

beforeEach(() => {
  fetchMock = vi.fn()
  vi.stubGlobal("fetch", fetchMock)
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

// ── 19.5 ::token_lives_only_in_module_memory ────────────────────────────────
describe("access-token-store — el token vive sólo en memoria", () => {
  it("entrega el token que devuelve el manejador", async () => {
    respondWith(withSession())
    const store = await loadStore()

    expect(await store.getAccessToken()).toBe(TOKEN)
    expect(String(fetchMock.mock.calls[0][0])).toContain("/api/auth/token")
  })

  it("no escribe ninguna cookie", async () => {
    respondWith(withSession())
    const store = await loadStore()

    const before = document.cookie
    await store.getAccessToken()

    expect(document.cookie).toBe(before)
    expect(document.cookie).not.toContain(TOKEN)
  })

  it("no escribe en localStorage ni en sessionStorage", async () => {
    respondWith(withSession())
    // El espía va sobre `Storage.prototype`, no sobre la instancia: en jsdom
    // `localStorage` es un Proxy y asignarle una propiedad —que es lo que hace
    // `vi.spyOn(window.localStorage, …)`— **guarda una clave llamada `setItem`**,
    // ensuciando justo lo que el test mide.
    const setItem = vi.spyOn(Storage.prototype, "setItem")
    const store = await loadStore()

    await store.getAccessToken()

    expect(setItem).not.toHaveBeenCalled()
    expect(window.localStorage.length).toBe(0)
    expect(window.sessionStorage.length).toBe(0)
    setItem.mockRestore()
  })

  it("el espía de almacenamiento no es vacuo", () => {
    const setItem = vi.spyOn(Storage.prototype, "setItem")
    window.sessionStorage.setItem("prueba", "1")
    expect(setItem).toHaveBeenCalledWith("prueba", "1")
    window.sessionStorage.clear()
    setItem.mockRestore()
  })

  it("la segunda lectura sale de memoria: un solo pedido al servidor", async () => {
    respondWith(withSession())
    const store = await loadStore()

    expect(await store.getAccessToken()).toBe(TOKEN)
    expect(await store.getAccessToken()).toBe(TOKEN)
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it("dos lecturas concurrentes comparten un solo pedido", async () => {
    // Cada carga de página dispara varias llamadas a PostgREST a la vez y todas
    // pasan por el callback: sin single-flight son N pedidos idénticos.
    respondWith(withSession())
    const store = await loadStore()

    const [a, b] = await Promise.all([store.getAccessToken(), store.getAccessToken()])

    expect(a).toBe(TOKEN)
    expect(b).toBe(TOKEN)
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it("el pedido viaja con las cookies del propio origen y sin caché", async () => {
    respondWith(withSession())
    const store = await loadStore()
    await store.getAccessToken()

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(init.credentials).toBe("same-origin")
    expect(init.cache).toBe("no-store")
  })

  it("`clearAccessToken()` lo borra de memoria", async () => {
    respondWith(withSession(), withoutSession())
    const store = await loadStore()

    expect(await store.getAccessToken()).toBe(TOKEN)
    store.clearAccessToken()

    // Sin sesión después del cierre: el valor viejo no puede sobrevivir.
    expect(await store.getAccessToken()).toBeNull()
  })
})

// ── 19.5b ::resolves_null_and_never_throws_without_session ──────────────────
describe("access-token-store — sin sesión resuelve vacío y nunca lanza", () => {
  it("sin sesión devuelve null", async () => {
    respondWith(withoutSession())
    const store = await loadStore()

    await expect(store.getAccessToken()).resolves.toBeNull()
  })

  it("con el pedido caído devuelve null en vez de lanzar", async () => {
    // Si el callback LANZA, `fetchWithAuth` no cae a la anon key
    // (`supabase-js/index.mjs:112`) y **toda** página pública que toque
    // supabase-js se rompe para un visitante anónimo.
    fetchMock.mockRejectedValue(new Error("red caída"))
    const store = await loadStore()

    await expect(store.getAccessToken()).resolves.toBeNull()
  })

  it("con una respuesta no-ok devuelve null en vez de lanzar", async () => {
    fetchMock.mockResolvedValue({ ok: false, status: 403, json: async () => ({}) } as Response)
    const store = await loadStore()

    await expect(store.getAccessToken()).resolves.toBeNull()
  })

  it("con un cuerpo que no es JSON devuelve null en vez de lanzar", async () => {
    fetchMock.mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => {
        throw new Error("Unexpected token <")
      },
    } as unknown as Response)
    const store = await loadStore()

    await expect(store.getAccessToken()).resolves.toBeNull()
  })

  it("no reintenta el null dentro de la misma carga de página", async () => {
    // Costo declarado en D1: la ida y vuelta extra se acota no repitiéndola
    // cuando el servidor ya dijo que no hay sesión.
    respondWith(withoutSession())
    const store = await loadStore()

    await store.getAccessToken()
    await store.getAccessToken()
    await store.getAccessToken()

    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it("`resolveAccessToken()` distingue 'no hay sesión' de 'no pude averiguarlo'", async () => {
    // El transporte del 401 necesita la distinción: un fallo de la consulta no es
    // una sesión ausente y no habilita a navegar al login (MINOR 4 de la Parte B).
    respondWith(withoutSession())
    const sinSesion = await loadStore()
    expect((await sinSesion.resolveAccessToken()).status).toBe("absent")

    fetchMock.mockReset().mockRejectedValue(new Error("red caída"))
    const noSe = await loadStore()
    expect((await noSe.resolveAccessToken()).status).toBe("unknown")
  })

  it("un fallo transitorio SÍ se reintenta (a diferencia del null)", async () => {
    fetchMock.mockRejectedValueOnce(new Error("red caída"))
    respondWith(withSession())
    const store = await loadStore()

    expect(await store.getAccessToken()).toBeNull()
    expect(await store.getAccessToken()).toBe(TOKEN)
  })
})

// ── 19.5 ::renews_before_expiry / on_visibilitychange / after_401 ───────────
describe("access-token-store — cuándo se renueva", () => {
  it("un token a punto de vencer se renueva en la lectura siguiente", async () => {
    respondWith(withSession(TOKEN, 10), withSession(NEXT_TOKEN, 3600))
    const store = await loadStore()

    expect(await store.getAccessToken()).toBe(TOKEN)
    // 10 s de vida restante está dentro del margen: el token que se entregaría
    // vencería en vuelo.
    expect(await store.getAccessToken()).toBe(NEXT_TOKEN)
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it("un token con vida de sobra NO se renueva", async () => {
    respondWith(withSession(TOKEN, 3600))
    const store = await loadStore()

    await store.getAccessToken()
    await store.getAccessToken()

    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it("se agenda la renovación antes del vencimiento, sin que nadie lo pida", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    respondWith(withSession(TOKEN, 300), withSession(NEXT_TOKEN, 3600))
    const store = await loadStore()

    await store.getAccessToken()
    expect(fetchMock).toHaveBeenCalledTimes(1)

    // El temporizador dispara antes del vencimiento: una pestaña abierta y quieta
    // no debe quedarse con un token muerto esperando la próxima interacción.
    await vi.advanceTimersByTimeAsync(300_000)

    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(await store.getAccessToken()).toBe(NEXT_TOKEN)
  })

  it("al volver a la pestaña con el token vencido renueva", async () => {
    // Los temporizadores de una pestaña de fondo se estrangulan, así que volver a
    // ella es el momento en que hay que revisar.
    respondWith(withSession(TOKEN, 10), withSession(NEXT_TOKEN, 3600))
    const store = await loadStore()
    await store.getAccessToken()

    document.dispatchEvent(new Event("visibilitychange"))
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2))

    expect(await store.getAccessToken()).toBe(NEXT_TOKEN)
  })

  it("al volver a la pestaña con el token fresco NO pide nada", async () => {
    // Control negativo: sin esto, cada cambio de pestaña sería un pedido, también
    // en las páginas públicas de un visitante anónimo.
    respondWith(withSession(TOKEN, 3600))
    const store = await loadStore()
    await store.getAccessToken()

    document.dispatchEvent(new Event("visibilitychange"))
    await Promise.resolve()

    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it("tras un 401 la renovación forzada trae el token nuevo", async () => {
    respondWith(withSession(TOKEN, 3600), withSession(NEXT_TOKEN, 3600))
    const store = await loadStore()

    expect(await store.getAccessToken()).toBe(TOKEN)
    // `refreshAccessToken()` es el camino del 401: ignora el caché a propósito,
    // porque el 401 es la evidencia de que lo cacheado ya no sirve.
    expect((await store.refreshAccessToken()).status).toBe("active")
    expect(await store.getAccessToken()).toBe(NEXT_TOKEN)
  })

  it("la renovación forzada también recupera de un 'no hay sesión' previo", async () => {
    // Después de iniciar sesión por la acción de servidor, el estado "ausente"
    // cacheado tiene que poder invalidarse o la app queda anónima hasta recargar.
    respondWith(withoutSession(), withSession())
    const store = await loadStore()

    expect(await store.getAccessToken()).toBeNull()
    await store.refreshAccessToken()

    expect(await store.getAccessToken()).toBe(TOKEN)
  })
})

// ── Identidad: el "contexto de sesión" para código que no es React ──────────
describe("access-token-store — identidad para los módulos sin hooks", () => {
  it("expone el usuario que viaja con el token", async () => {
    respondWith(withSession())
    const store = await loadStore()

    expect(await store.getSessionUser()).toEqual(USER)
  })

  it("sin sesión el usuario es null", async () => {
    respondWith(withoutSession())
    const store = await loadStore()

    expect(await store.getSessionUser()).toBeNull()
  })

  it("no vuelve a pedirlo si ya lo tiene en memoria", async () => {
    respondWith(withSession())
    const store = await loadStore()

    await store.getSessionUser()
    await store.getAccessToken()

    expect(fetchMock).toHaveBeenCalledTimes(1)
  })
})

// ── Suscripción: lo que Realtime necesita (19.9) ───────────────────────────
describe("access-token-store — avisa cuando el token cambia", () => {
  it("notifica al suscriptor en cada renovación", async () => {
    respondWith(withSession(TOKEN, 3600), withSession(NEXT_TOKEN, 3600))
    const store = await loadStore()
    const listener = vi.fn()
    store.subscribeToAccessToken(listener)

    await store.getAccessToken()
    await store.refreshAccessToken()

    expect(listener).toHaveBeenCalledTimes(2)
  })

  it("la baja deja de notificar", async () => {
    respondWith(withSession(TOKEN, 3600), withSession(NEXT_TOKEN, 3600))
    const store = await loadStore()
    const listener = vi.fn()
    const unsubscribe = store.subscribeToAccessToken(listener)

    await store.getAccessToken()
    unsubscribe()
    await store.refreshAccessToken()

    expect(listener).toHaveBeenCalledTimes(1)
  })

  it("un suscriptor que lanza no rompe la renovación de los demás", async () => {
    respondWith(withSession())
    const store = await loadStore()
    const sano = vi.fn()
    store.subscribeToAccessToken(() => {
      throw new Error("consumidor roto")
    })
    store.subscribeToAccessToken(sano)

    await expect(store.getAccessToken()).resolves.toBe(TOKEN)
    expect(sano).toHaveBeenCalledTimes(1)
  })
})

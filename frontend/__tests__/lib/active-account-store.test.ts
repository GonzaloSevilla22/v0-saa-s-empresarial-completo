/**
 * multiusuario-operativo tanda A (D6) — `lib/auth/active-account-store.ts`.
 *
 * Guarda UNA cosa que los módulos que no son React necesitan saber: qué cuenta
 * está mostrando la pantalla (para declararla en `X-Account-Id`), y a quién
 * avisarle cuando el backend dice que esa cuenta quedó vieja (el 409
 * `account_switched` o el 403 de "sin cuenta activa"). El proveedor de auth se
 * registra como quien resincroniza.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import {
  getDisplayedAccountId,
  registerAccountResync,
  requestAccountResync,
  resetActiveAccountStore,
  setDisplayedAccountId,
} from "@/lib/auth/active-account-store"

beforeEach(() => {
  resetActiveAccountStore()
})

describe("cuenta que muestra la pantalla", () => {
  it("arranca sin cuenta declarada", () => {
    expect(getDisplayedAccountId()).toBeNull()
  })

  it("guarda y limpia la cuenta", () => {
    setDisplayedAccountId("acc-1")
    expect(getDisplayedAccountId()).toBe("acc-1")
    setDisplayedAccountId(null)
    expect(getDisplayedAccountId()).toBeNull()
  })

  it("una cadena vacía cuenta como ausente (el contexto usa '' cuando no hay cuenta)", () => {
    setDisplayedAccountId("")
    expect(getDisplayedAccountId()).toBeNull()
  })
})

describe("resincronización", () => {
  it("sin nadie registrado no hace nada y lo informa", async () => {
    await expect(requestAccountResync("switched")).resolves.toBe(false)
  })

  it("llama al registrado con el motivo", async () => {
    const handler = vi.fn().mockResolvedValue(undefined)
    registerAccountResync(handler)
    await expect(requestAccountResync("switched")).resolves.toBe(true)
    expect(handler).toHaveBeenCalledWith("switched")
  })

  it("pedidos simultáneos comparten UNA sola corrida (varios requests fallando juntos no disparan N renovaciones)", async () => {
    let release: () => void = () => {}
    const handler = vi.fn(
      () =>
        new Promise<void>((resolve) => {
          release = resolve
        }),
    )
    registerAccountResync(handler)

    const first = requestAccountResync("switched")
    const second = requestAccountResync("switched")
    const third = requestAccountResync("no-active-account")
    release()
    await Promise.all([first, second, third])

    expect(handler).toHaveBeenCalledTimes(1)
  })

  it("terminada la corrida, un pedido nuevo vuelve a correr", async () => {
    const handler = vi.fn().mockResolvedValue(undefined)
    registerAccountResync(handler)
    await requestAccountResync("switched")
    await requestAccountResync("switched")
    expect(handler).toHaveBeenCalledTimes(2)
  })

  it("la función de baja deja de recibir pedidos", async () => {
    const handler = vi.fn().mockResolvedValue(undefined)
    const unregister = registerAccountResync(handler)
    unregister()
    await expect(requestAccountResync("switched")).resolves.toBe(false)
    expect(handler).not.toHaveBeenCalled()
  })

  it("un manejador que falla no rompe al pedido: se traga y se informa por consola", async () => {
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {})
    registerAccountResync(vi.fn().mockRejectedValue(new Error("se cayó")))
    await expect(requestAccountResync("switched")).resolves.toBe(true)
    expect(consoleError).toHaveBeenCalled()
    consoleError.mockRestore()
  })
})

describe("tope del pedido 'sin cuenta activa'", () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-10-16T12:00:00Z"))
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it("un usuario sin ninguna membresía recibe el 403 de TODOS sus requests: el segundo pedido seguido NO resincroniza otra vez (evita el lazo)", async () => {
    const handler = vi.fn().mockResolvedValue(undefined)
    registerAccountResync(handler)

    await expect(requestAccountResync("no-active-account")).resolves.toBe(true)
    await expect(requestAccountResync("no-active-account")).resolves.toBe(false)

    expect(handler).toHaveBeenCalledTimes(1)
  })

  it("pasado el tope vuelve a resincronizar", async () => {
    const handler = vi.fn().mockResolvedValue(undefined)
    registerAccountResync(handler)

    await requestAccountResync("no-active-account")
    vi.setSystemTime(new Date("2026-10-16T12:00:16Z"))
    await expect(requestAccountResync("no-active-account")).resolves.toBe(true)

    expect(handler).toHaveBeenCalledTimes(2)
  })

  it("'switched' NO se limita: es un hecho puntual, no una condición persistente", async () => {
    const handler = vi.fn().mockResolvedValue(undefined)
    registerAccountResync(handler)

    await requestAccountResync("no-active-account")
    await expect(requestAccountResync("switched")).resolves.toBe(true)
    await expect(requestAccountResync("switched")).resolves.toBe(true)

    expect(handler).toHaveBeenCalledTimes(3)
  })
})

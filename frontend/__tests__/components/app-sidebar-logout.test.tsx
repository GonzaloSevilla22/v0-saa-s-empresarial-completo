/**
 * auth-hardening-jwt-cookies — D6, task 14.9.
 *
 * El botón del sidebar lanzaba `logout()` y en la línea SIGUIENTE forzaba
 * `window.location.href = "/"` (`components/app-sidebar.tsx:353-355`): la
 * navegación salía antes de que la revocación contra el proveedor y el borrado
 * de cookies terminaran, y `logout()` relanza su error sin `.catch()` en el
 * call site, así que un fallo quedaba como promesa rechazada sin manejar.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { handleSidebarLogout } from "@/components/app-sidebar"

let navigated: string[] = []
const navigate = (url: string) => {
  navigated.push(url)
}

beforeEach(() => {
  navigated = []
  vi.restoreAllMocks()
})

describe("handleSidebarLogout — ::awaits_logout_before_navigating", () => {
  it("no navega hasta que el logout termina", async () => {
    let resolveLogout: () => void = () => {}
    const logout = vi.fn(
      () =>
        new Promise<void>((resolve) => {
          resolveLogout = resolve
        }),
    )

    const pending = handleSidebarLogout(logout, navigate)

    // El logout está en vuelo: la navegación todavía no ocurrió.
    expect(logout).toHaveBeenCalledTimes(1)
    expect(navigated).toEqual([])

    resolveLogout()
    await pending

    expect(navigated).toEqual(["/"])
  })

  it("navega a la raíz cuando el logout resuelve", async () => {
    await handleSidebarLogout(vi.fn().mockResolvedValue(undefined), navigate)
    expect(navigated).toEqual(["/"])
  })

  it("si el logout falla igual navega, y el error no queda sin manejar", async () => {
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {})
    const logout = vi.fn().mockRejectedValue(new Error("GoTrue no responde"))

    await expect(handleSidebarLogout(logout, navigate)).resolves.toBeUndefined()

    expect(navigated).toEqual(["/"])
    expect(consoleError).toHaveBeenCalled()
  })

  it("navega una sola vez", async () => {
    await handleSidebarLogout(vi.fn().mockResolvedValue(undefined), navigate)
    expect(navigated).toHaveLength(1)
  })
})

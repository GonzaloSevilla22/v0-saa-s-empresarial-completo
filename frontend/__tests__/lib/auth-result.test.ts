/**
 * auth-hardening-jwt-cookies — Parte C, grupo 18.
 *
 * Las acciones de auth **devuelven** el error del proveedor en vez de lanzarlo:
 * una excepción dentro de una Server Action le llega al navegador enmascarada
 * por Next, sin mensaje. Este helper es el que reconstruye el contrato que las
 * cuatro pantallas de auth ya tienen (`toast.error(error.message)`), y por eso
 * tiene su propio test: si se tragara el `{ ok: false }`, una operación fallida
 * se vería como exitosa en las cinco superficies a la vez.
 */
import { describe, it, expect } from "vitest"
import { unwrapAuthResult } from "@/lib/auth/auth-result"

describe("unwrapAuthResult", () => {
  it("con ok no hace nada", () => {
    expect(() => unwrapAuthResult({ ok: true })).not.toThrow()
  })

  it("con error lanza con el mensaje TAL CUAL del proveedor", () => {
    expect(() => unwrapAuthResult({ ok: false, error: "Invalid login credentials" })).toThrow(
      "Invalid login credentials",
    )
  })

  it("y lo lanza como Error, que es lo que las pantallas leen con .message", () => {
    try {
      unwrapAuthResult({ ok: false, error: "User already registered" })
      expect.unreachable("tenía que lanzar")
    } catch (error) {
      expect(error).toBeInstanceOf(Error)
      expect((error as Error).message).toBe("User already registered")
    }
  })

  it("un mensaje vacío también lanza (el fallo no se pierde por falta de texto)", () => {
    // Borde real: GoTrue puede devolver un error sin mensaje útil. Lo que no
    // puede pasar es que eso se lea como éxito.
    expect(() => unwrapAuthResult({ ok: false, error: "" })).toThrow()
  })
})

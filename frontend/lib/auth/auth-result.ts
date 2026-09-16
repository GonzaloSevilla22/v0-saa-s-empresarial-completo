/**
 * auth-result.ts — el contrato de vuelta de las acciones de auth de servidor.
 *
 * auth-hardening-jwt-cookies (Parte C, D1, grupo 18). Las acciones **devuelven**
 * el error del proveedor en vez de lanzarlo, por una razón concreta y no
 * estética: una excepción dentro de una Server Action le llega al navegador
 * enmascarada por Next (`An error occurred in the Server Components render`,
 * sin mensaje, en producción). Las cuatro pantallas de auth muestran hoy
 * `error.message` en un toast —"Invalid login credentials", "User already
 * registered", "For security purposes, you can only request this after 60
 * seconds"—, y eso es información que el usuario necesita.
 *
 * Este módulo vive **fuera** del archivo `"use server"` porque todo export de un
 * módulo de acciones tiene que ser una función asíncrona: un helper síncrono ahí
 * rompe el build.
 */

/** Resultado de una operación de auth de servidor. */
export type AuthActionResult = { ok: true } | { ok: false; error: string }

/**
 * Convierte el resultado en el contrato que las pantallas ya tienen (lanzar con
 * el mensaje del proveedor), para que el recableado no toque su manejo de error
 * ni su UI.
 */
export function unwrapAuthResult(result: AuthActionResult): void {
  if (!result.ok) throw new Error(result.error)
}

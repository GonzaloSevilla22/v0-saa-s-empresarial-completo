/**
 * /proveedores debe quedar gateada por auth (compras-proveedor-cuenta-corriente,
 * task 11.4/11.5). Sin esto, un usuario no autenticado podría acceder a la ruta
 * directamente (mismo riesgo que /clientes, /compras, etc.).
 *
 * auth-hardening-jwt-cookies (D4, task 12.5): la aserción se conserva íntegra,
 * pero cambia de forma. `PROTECTED_PREFIXES` (la lista enumerada a mano) se
 * retiró porque ese mecanismo es el que produjo F1 — 12 árboles del dashboard
 * sin gate. La protección ahora es por exclusión y se pregunta con
 * `isProtectedPath()`.
 */
import { describe, it, expect } from "vitest"
import { isProtectedPath } from "@/lib/supabase/middleware"

describe("/proveedores está protegida", () => {
  it("exige sesión", () => {
    expect(isProtectedPath("/proveedores")).toBe(true)
  })

  it("también sus subrutas", () => {
    expect(isProtectedPath("/proveedores/abc-123")).toBe(true)
  })
})

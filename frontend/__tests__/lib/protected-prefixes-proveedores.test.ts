/**
 * PROTECTED_PREFIXES — /proveedores debe quedar gateada por auth (compras-proveedor-cuenta-corriente,
 * task 11.4/11.5). Sin esto, un usuario no autenticado podría acceder a la ruta
 * directamente (mismo riesgo que /clientes, /compras, etc.).
 */
import { describe, it, expect } from "vitest"
import { PROTECTED_PREFIXES } from "@/lib/supabase/middleware"

describe("PROTECTED_PREFIXES — /proveedores", () => {
  it("incluye /proveedores", () => {
    expect(PROTECTED_PREFIXES).toContain("/proveedores")
  })
})

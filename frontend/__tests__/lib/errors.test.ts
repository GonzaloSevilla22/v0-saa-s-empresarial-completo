import { describe, it, expect } from "vitest"
import { getErrorMessage } from "@/lib/errors"

// review B (FE-4/FE-5/SEC-2/SPEC-02): helper para reemplazar `catch (err: any)`
// por `catch (err: unknown)` con narrowing explícito — nunca `any` (regla del
// proyecto). Usado por supplier-form.tsx, proveedores/page.tsx y
// purchase-form.tsx (handleCreateSupplier).

describe("getErrorMessage", () => {
  it("un Error con message devuelve ese message", () => {
    expect(getErrorMessage(new Error("CUIT inválido"), "fallback")).toBe("CUIT inválido")
  })

  it("un Error con message vacío devuelve el fallback (TRIANGULATE)", () => {
    expect(getErrorMessage(new Error(""), "fallback")).toBe("fallback")
  })

  it("un valor que no es Error (string, objeto plano, undefined) devuelve el fallback", () => {
    expect(getErrorMessage("boom", "fallback")).toBe("fallback")
    expect(getErrorMessage({ detail: "boom" }, "fallback")).toBe("fallback")
    expect(getErrorMessage(undefined, "fallback")).toBe("fallback")
    expect(getErrorMessage(null, "fallback")).toBe("fallback")
  })
})

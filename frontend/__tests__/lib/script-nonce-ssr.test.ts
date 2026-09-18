// @vitest-environment node
/**
 * fix/comprobante-print-csp-nonce.
 *
 * `getDocumentScriptNonce` puede llamarse desde código compartido que también
 * corre en el servidor (SSR) — sin `document`, tiene que devolver `undefined`
 * en vez de lanzar.
 */
import { describe, it, expect } from "vitest"
import { getDocumentScriptNonce } from "@/lib/script-nonce"

describe("getDocumentScriptNonce — sin document (SSR)", () => {
  it("devuelve undefined en vez de lanzar", () => {
    expect(typeof document).toBe("undefined")
    expect(getDocumentScriptNonce()).toBeUndefined()
  })
})

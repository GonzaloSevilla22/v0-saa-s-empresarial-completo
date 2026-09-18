/**
 * fix/comprobante-print-csp-nonce.
 *
 * `lib/supabase/middleware.ts` deja `script-src` sin `'unsafe-inline'` en
 * producción: todo `<script>` en línea necesita el nonce de la petición para
 * ejecutar. Un documento `blob:` HEREDA esa política del documento que creó la
 * URL (mismo policy container), así que el comprobante de venta generado en el
 * cliente (`lib/receipt.ts`) también necesita ESE nonce.
 *
 * El navegador oculta el ATRIBUTO de contenido `nonce` a propósito
 * (`getAttribute("nonce")` devuelve `""` una vez que el elemento entra al DOM,
 * para que un XSS que lea el árbol no pueda robarlo), pero la PROPIEDAD IDL
 * `.nonce` sí expone el valor real al código que corre en la página. Por eso
 * `getDocumentScriptNonce` lee la propiedad, nunca el atributo — aunque jsdom
 * (a diferencia de un navegador real) no implemente esa ocultación, así que acá
 * ambos caminos devuelven el mismo valor.
 */
import { describe, it, expect, afterEach } from "vitest"
import { getDocumentScriptNonce } from "@/lib/script-nonce"

afterEach(() => {
  document.head.innerHTML = ""
})

describe("getDocumentScriptNonce", () => {
  it("con un <script nonce> presente en el documento, devuelve su valor", () => {
    const script = document.createElement("script")
    script.setAttribute("nonce", "N0NC3-de-esta-carga")
    document.head.appendChild(script)

    expect(getDocumentScriptNonce()).toBe("N0NC3-de-esta-carga")
  })

  it("con un nonce distinto, devuelve ESE valor (no uno fijo)", () => {
    const script = document.createElement("script")
    script.setAttribute("nonce", "otro-nonce-completamente-distinto")
    document.head.appendChild(script)

    expect(getDocumentScriptNonce()).toBe("otro-nonce-completamente-distinto")
  })

  it("sin ningún <script nonce> en el documento, devuelve undefined", () => {
    // Ningún <script> en el head en este test (afterEach lo dejó vacío) y los
    // que monta jsdom para el propio test runner no llevan nonce.
    expect(getDocumentScriptNonce()).toBeUndefined()
  })
})

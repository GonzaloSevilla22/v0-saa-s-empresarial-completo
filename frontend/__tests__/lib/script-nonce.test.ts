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

  it("lee la PROPIEDAD IDL, no el atributo — un navegador real oculta el atributo", () => {
    // jsdom no reproduce la ocultación del atributo `nonce` que hacen los
    // navegadores reales (ver el comentario de cabecera): en jsdom
    // `getAttribute("nonce")` y la propiedad `.nonce` devuelven lo mismo, así
    // que ese camino equivocado (`script?.getAttribute("nonce")`) pasaría los
    // demás tests de este archivo igual de bien que el correcto. Este test
    // fuerza la distinción con `Object.defineProperty`, tal como la expone un
    // navegador real: atributo vacío, propiedad con el valor verdadero.
    const script = document.createElement("script")
    script.setAttribute("nonce", "") // lo que deja ver el navegador
    Object.defineProperty(script, "nonce", {
      value: "NONCE-REAL-OCULTO-EN-EL-ATRIBUTO",
      configurable: true,
    })
    document.head.appendChild(script)

    expect(script.getAttribute("nonce")).toBe("") // control: el atributo miente
    expect(getDocumentScriptNonce()).toBe("NONCE-REAL-OCULTO-EN-EL-ATRIBUTO")
  })
})

/**
 * Nonce de la política CSP de esta carga de documento, leído desde el DOM.
 *
 * fix/comprobante-print-csp-nonce. `lib/supabase/middleware.ts` dejó
 * `script-src` sin `'unsafe-inline'` en producción (auth-hardening-jwt-cookies,
 * D3): todo `<script>` en línea necesita el nonce de la petición para
 * ejecutar. Un documento `blob:` HEREDA esa política del documento que creó la
 * URL (mismo policy container) — así que un script inline armado en el
 * cliente (p. ej. el comprobante de venta de `lib/receipt.ts`) también
 * necesita ESE nonce, o queda bloqueado en silencio.
 *
 * El navegador oculta a propósito el ATRIBUTO de contenido `nonce` una vez que
 * el elemento entra al DOM (`getAttribute("nonce")` devuelve `""`, para que un
 * XSS que lea el árbol no pueda robarlo), pero la PROPIEDAD IDL `.nonce` sí
 * expone el valor real al código que corre en la página. Por eso esta función
 * lee la propiedad, nunca el atributo.
 *
 * Con la navegación de cliente de Next el nonce sigue siendo el de la carga
 * inicial del documento (Next no vuelve a pedir HTML en una navegación de
 * cliente), que es justo el nonce de la política CSP vigente.
 */
export function getDocumentScriptNonce(): string | undefined {
  if (typeof document === "undefined") return undefined
  const script = document.querySelector<HTMLScriptElement>("script[nonce]")
  return script?.nonce || undefined
}

/**
 * Botón flotante de contacto por WhatsApp para la landing pública.
 *
 * Server Component a propósito (sin `"use client"`): "siempre visible mientras
 * se hace scroll" es `position: fixed` puro y el hover son transiciones CSS, así
 * que no hay nada que hidratar. Se monta en `app/page.tsx` y NO dentro de
 * `LandingPageFull` (que sí es cliente): así no engorda el bundle de una landing
 * que ya carga una escena 3D, y el alcance queda estructuralmente limitado a la
 * home — al no vivir en un layout ni en un componente compartido, no puede
 * filtrarse a `/landing`, a auth ni al dashboard. Ver `design.md` D2.
 *
 * Change: `landing-whatsapp-fab`.
 */

import { aliadataWhatsAppUrl } from "@/lib/aliadata-contact"

/**
 * Nombra el destino y avisa que se sale del sitio: con un botón que es solo un
 * ícono, esto es lo único que anuncia un lector de pantalla.
 */
const ACCESSIBLE_LABEL = "Escribinos por WhatsApp (se abre en una pestaña nueva)"

/**
 * Verde oficial de WhatsApp. Deliberadamente NO es un token semántico del design
 * system: el color corporativo de un tercero no es "primary" ni "success", es
 * "WhatsApp", y cambiaría el reconocimiento de marca si lo tokenizáramos. El
 * resto del estilado (elevación, duración, easing) sí usa tokens. Ver `design.md` D5.
 */
const WHATSAPP_BRAND_GREEN = "#25D366"

export function WhatsAppFab({ phone }: { phone?: string }) {
  // La validación (y el porqué de validar ANTES de armar la URL) vive en
  // `lib/aliadata-contact.ts` — compartida con el link "Contacto" del footer.
  // Sin número válido preferimos no renderizar nada (design.md D3).
  const url = aliadataWhatsAppUrl(phone)
  if (!url) return null

  return (
    <a
      href={url}
      target="_blank"
      // Sin `noopener`, la pestaña destino recibe `window.opener` y puede
      // redirigir la nuestra (tabnabbing).
      rel="noopener noreferrer"
      aria-label={ACCESSIBLE_LABEL}
      // z-40: por debajo del navbar fijo de la landing y de los overlays de
      // shadcn (ambos z-50), por encima de todo el contenido. h-14/w-14 = 56px,
      // holgado sobre el mínimo táctil de 44px.
      className="fixed bottom-5 right-5 z-40 flex h-14 w-14 items-center justify-center rounded-full text-white shadow-elevation-3 transition-transform duration-fast ease-standard hover:scale-105 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-white focus-visible:ring-offset-2 focus-visible:ring-offset-slate-950 motion-reduce:transition-none motion-reduce:hover:scale-100 sm:bottom-6 sm:right-6"
      style={{ backgroundColor: WHATSAPP_BRAND_GREEN }}
    >
      {/* Glifo oficial de WhatsApp: `lucide-react` no incluye marcas
          comerciales. Inline y no <img> para no pagar un request ni un flash
          sin ícono, y para no depender de `img-src` del CSP. Decorativo: el
          nombre accesible lo aporta el `aria-label` del enlace. */}
      <svg
        aria-hidden="true"
        focusable="false"
        viewBox="0 0 24 24"
        fill="currentColor"
        className="h-7 w-7"
      >
        <path d="M17.472 14.382c-.297-.149-1.758-.867-2.03-.967-.273-.099-.471-.148-.67.15-.197.297-.767.966-.94 1.164-.173.199-.347.223-.644.075-.297-.15-1.255-.463-2.39-1.475-.883-.788-1.48-1.761-1.653-2.059-.173-.297-.018-.458.13-.606.134-.133.298-.347.446-.52.149-.174.198-.298.298-.497.099-.198.05-.371-.025-.52-.075-.149-.669-1.612-.916-2.207-.242-.579-.487-.5-.669-.51-.173-.008-.371-.01-.57-.01-.198 0-.52.074-.792.372-.272.297-1.04 1.016-1.04 2.479 0 1.462 1.065 2.875 1.213 3.074.149.198 2.096 3.2 5.077 4.487.709.306 1.262.489 1.694.625.712.227 1.36.195 1.871.118.571-.085 1.758-.719 2.006-1.413.248-.694.248-1.289.173-1.413-.074-.124-.272-.198-.57-.347m-5.421 7.403h-.004a9.87 9.87 0 0 1-5.031-1.378l-.361-.214-3.741.982.998-3.648-.235-.374a9.86 9.86 0 0 1-1.51-5.26c.001-5.45 4.436-9.884 9.888-9.884 2.64 0 5.122 1.03 6.988 2.898a9.825 9.825 0 0 1 2.893 6.994c-.003 5.45-4.437 9.884-9.885 9.884m8.413-18.297A11.815 11.815 0 0 0 12.05 0C5.495 0 .16 5.335.157 11.892c0 2.096.547 4.142 1.588 5.945L.057 24l6.305-1.654a11.882 11.882 0 0 0 5.683 1.448h.005c6.554 0 11.89-5.335 11.893-11.893a11.821 11.821 0 0 0-3.48-8.413Z" />
      </svg>
    </a>
  )
}

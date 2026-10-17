import type { Metadata } from "next"
import { InvitationAcceptance } from "@/components/invitations/InvitationAcceptance"

/**
 * /invitacion/[token] — la pantalla pública de aceptación de una invitación.
 *
 * multiusuario-operativo tanda C (D12). El token viaja en el PATH, así que esta ruta:
 *   · NO se indexa (`robots`) y su encabezado sale con `X-Robots-Tag: noindex` (middleware);
 *   · NO manda el `Referer` a ningún lado (`referrer: no-referrer` acá y `Referrer-Policy: no-referrer`
 *     en la respuesta, `lib/supabase/middleware.ts`);
 *   · es PÚBLICA (`lib/auth/route-access.ts`): el visitante sin sesión ve un mensaje genérico con
 *     «Ingresar» / «Crear cuenta»; qué mostrar lo decide `InvitationAcceptance` según la identidad.
 */
export const metadata: Metadata = {
  title: "Invitación - ALIADATA",
  robots: { index: false, follow: false, nocache: true, noarchive: true },
  referrer: "no-referrer",
}

export default async function InvitacionPage({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params
  return <InvitationAcceptance token={token} />
}

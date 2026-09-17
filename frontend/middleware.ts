import { type NextRequest } from 'next/server'
import { updateSession, generateCspNonce } from '@/lib/supabase/middleware'

export async function middleware(request: NextRequest) {
  // auth-hardening-jwt-cookies (D3, task 21.6): el nonce de la CSP se genera
  // **una sola vez por petición**, acá, y se reutiliza para todos los scripts de
  // esa respuesta. `updateSession` lo pone en los encabezados de la petición
  // reenviada (junto a la política completa, que es de donde Next lo lee para
  // firmar sus propios scripts de arranque e hidratación) y en la política que
  // emite la respuesta. Generarlo dos veces = dos nonces distintos = pantalla en
  // blanco bajo `'strict-dynamic'`.
  //
  // Consecuencia declarada (task 21.9): un valor que cambia por petición saca de
  // render estático a las páginas que hoy se prerenderizan. Las del dashboard ya
  // eran dinámicas por cookies; el costo de latencia en las públicas se acepta, y
  // NO es un motivo para ampliar la política.
  return await updateSession(request, generateCspNonce())
}

export const config = {
  matcher: [
    /*
     * Match all request paths except for the ones starting with:
     * - _next/static (static files)
     * - _next/image (image optimization files)
     * - favicon.ico (favicon file)
     * Feel free to modify this pattern to include more paths.
     */
    '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)',
  ],
}

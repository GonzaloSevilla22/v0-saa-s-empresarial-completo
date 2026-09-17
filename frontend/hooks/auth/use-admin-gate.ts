"use client"

/**
 * use-admin-gate.ts — el gate de administrador de las pantallas de `/admin`.
 *
 * auth-hardening-jwt-cookies (Parte C, D1, task 19.8d). Trece pantallas de admin
 * tenían **la misma** copia de este bloque:
 *
 *     const { data: { user } } = await supabase.auth.getUser()
 *     if (!user) { window.location.href = '/auth'; return }
 *     const { data: profile } = await supabase
 *       .from('profiles').select('role').eq('id', user.id).single()
 *     if (!profile || profile.role !== 'admin') { … }
 *
 * Con el cliente configurado con `accessToken` (19.6) ese `getUser()` **lanza**
 * (`supabase-js/index.mjs:389`), así que las trece había que tocarlas igual. En vez
 * de trece reemplazos idénticos, la decisión vive acá: `useAuth()` ya resolvió el
 * usuario **y** su rol en el arranque de la app, así que el gate no necesita ni
 * red ni una consulta a `profiles`.
 *
 * Tres cosas que se corrigen de paso:
 *
 *  - **Una consulta menos por pantalla.** El `SELECT role FROM profiles` era la
 *    cuarta copia de un dato que el contexto de sesión ya tiene.
 *  - **`window.location.href = '/auth'` era un 404.** No existe `app/auth/page.tsx`
 *    — el login vive en `/auth/login`. Misma familia que el hallazgo F2 que la
 *    Parte B cerró para `/login`. Lo tapaba el gate del middleware, que atajaba al
 *    visitante anónimo antes de llegar a la pantalla; la rama era alcanzable sólo
 *    si ese gate fallaba, que es justo cuando uno no quiere un 404.
 *  - **Navegación por el router**, no por `window.location`: un `href` recarga la
 *    app entera y tira el estado de la sesión en curso.
 */
import { useEffect } from "react"
import { useRouter } from "next/navigation"
import { useAuth } from "@/contexts/auth-context"

/**
 * Sólo dos estados, y no hay un "checking" ausente por olvido: `AuthProvider` no
 * renderiza a sus hijos hasta terminar la comprobación inicial de sesión
 * (`contexts/auth-context.tsx`), así que cuando una pantalla de admin corre, el
 * usuario ya está resuelto. Un tercer estado sería inalcanzable e invitaría a
 * ramas muertas.
 */
export type AdminGateState = "allowed" | "denied"

/**
 * ¿Puede esta pantalla mostrarse? Cuando no, dispara la navegación al destino
 * correcto y devuelve `"denied"` para que el consumidor no renderice ni cargue
 * datos.
 *
 * Es defensa en profundidad de pantalla, no el control de acceso: el middleware
 * ya comprueba el rol contra la base para todo `/admin/**`
 * (`lib/supabase/middleware.ts`), y la RLS es la red final.
 */
export function useAdminGate(): AdminGateState {
  const { user, isAdmin } = useAuth()
  const router = useRouter()

  useEffect(() => {
    if (!user) {
      router.replace("/auth/login")
      return
    }
    if (!isAdmin) router.replace("/dashboard")
  }, [user, isAdmin, router])

  return user && isAdmin ? "allowed" : "denied"
}

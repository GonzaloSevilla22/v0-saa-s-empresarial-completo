/**
 * banco-caja-historial-ajustes (D8): Banco pasa a ser un módulo propio en
 * `/banco`, con la conciliación adentro (tab). Redirect server-side, sin
 * useEffect ni pantalla intermedia — cero lógica duplicada, la pantalla
 * completa vive en `/banco`.
 */
import { redirect } from "next/navigation"

export default function ConciliacionRedirectPage() {
  redirect("/banco?tab=conciliacion")
}

/**
 * banco-caja-historial-ajustes (D8): Caja pasa a ser un módulo propio en
 * `/caja`. Esta ruta se conserva como acceso CONTEXTUAL desde el detalle de
 * sucursal y redirige — server-side, sin useEffect ni pantalla intermedia,
 * para que no haya flash ni links rotos en marcadores del PO. Cero lógica
 * duplicada: toda la pantalla (selector de caja, sesión, ajuste, historial)
 * vive en `/caja`.
 */
import { redirect } from "next/navigation"

interface PageProps {
  params: Promise<{ id: string }>
}

export default async function BranchCajaRedirectPage({ params }: PageProps) {
  const { id } = await params
  redirect(`/caja?branch=${id}`)
}

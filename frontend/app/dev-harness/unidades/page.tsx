import { notFound } from "next/navigation"
import { UnidadesHarness } from "./UnidadesHarness"

// ventas-unidades-conversion: arnés de navegador real para la pasada visual
// del listado de stock con unidades, del historial de movimientos y del
// selector de unidad compatible del formulario de venta (ver
// app/dev-harness/README.md). Sólo existe en desarrollo.
export default function Page() {
  if (process.env.NODE_ENV === "production") notFound()
  return <UnidadesHarness />
}

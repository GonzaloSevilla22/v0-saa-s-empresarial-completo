import { notFound } from "next/navigation"
import { TableroHarness } from "./TableroHarness"

// tablero-explicable: arnés de navegador real para la pasada visual del
// gráfico con rango y comparación, las tarjetas «de dónde sale», la campana
// accionable y el Resumen IA del día (ver app/dev-harness/README.md). Sólo
// existe en desarrollo — en un build de producción la ruta es 404.
export default function Page() {
  if (process.env.NODE_ENV === "production") notFound()
  return <TableroHarness />
}

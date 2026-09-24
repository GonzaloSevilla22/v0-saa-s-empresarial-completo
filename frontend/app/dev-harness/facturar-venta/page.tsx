import { notFound } from "next/navigation"
import { FacturarVentaHarness } from "./FacturarVentaHarness"

// venta-editable-vs-promocion-legacy: arnés de navegador real para la pasada
// visual de los caminos de error de "Facturar" (ver app/dev-harness/README.md).
// Sólo existe en desarrollo.
export default function Page() {
  if (process.env.NODE_ENV === "production") notFound()
  return <FacturarVentaHarness />
}

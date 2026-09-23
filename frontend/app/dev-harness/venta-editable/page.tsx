import { notFound } from "next/navigation"
import { VentaEditableHarness } from "./VentaEditableHarness"

// venta-editable-sin-cae: arnés de navegador real para la pasada visual del
// listado, el formulario y la confirmación de anulación (ver
// app/dev-harness/README.md). Sólo existe en desarrollo.
export default function Page() {
  if (process.env.NODE_ENV === "production") notFound()
  return <VentaEditableHarness />
}

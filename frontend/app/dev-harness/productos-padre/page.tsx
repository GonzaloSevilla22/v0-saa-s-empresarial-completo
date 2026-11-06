import { notFound } from "next/navigation"
import { ProductosPadreHarness } from "./ProductosPadreHarness"

// productos-padre-variantes (task 12.2): arnés de navegador real para la pasada visual de /productos
// — paso «¿Qué querés crear?», los tres formularios, «Corregir unidad» y «Modificar precios»
// (ver app/dev-harness/README.md). Sólo existe en desarrollo.
export default function Page() {
  if (process.env.NODE_ENV === "production") notFound()
  return <ProductosPadreHarness />
}

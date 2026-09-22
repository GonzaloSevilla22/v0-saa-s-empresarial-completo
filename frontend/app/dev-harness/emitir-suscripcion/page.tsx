import { notFound } from "next/navigation"
import { EmitirSuscripcionHarness } from "./EmitirSuscripcionHarness"

// fiscal-emision-segura (G5/H3, task 5.5): arnés de navegador real para la
// pasada visual del diálogo de emisión (ver app/dev-harness/README.md).
// Sólo existe en desarrollo.
export default function Page() {
  if (process.env.NODE_ENV === "production") notFound()
  return <EmitirSuscripcionHarness />
}

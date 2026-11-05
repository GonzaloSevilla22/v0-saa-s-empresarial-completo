import { notFound } from "next/navigation"
import { OcrCuotaHarness } from "./OcrCuotaHarness"

// v31-ia-ratelimit-budget (task 4.9): arnés de navegador real para la pasada visual del
// diálogo «Leer factura con IA» (ver app/dev-harness/README.md). Sólo existe en desarrollo.
export default function Page() {
  if (process.env.NODE_ENV === "production") notFound()
  return <OcrCuotaHarness />
}

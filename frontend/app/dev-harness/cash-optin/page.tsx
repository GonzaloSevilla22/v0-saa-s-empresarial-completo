import { notFound } from "next/navigation"
import { CashOptinHarness } from "./CashOptinHarness"

// caja-optin-carga: arnés de navegador real para la pasada visual del bloque
// «Registrar en caja» en sus tres estados (ver app/dev-harness/README.md).
// Sólo existe en desarrollo.
export default function Page() {
  if (process.env.NODE_ENV === "production") notFound()
  return <CashOptinHarness />
}

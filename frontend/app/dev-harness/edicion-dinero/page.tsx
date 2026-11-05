import { notFound } from "next/navigation"
import { EdicionDineroHarness } from "./EdicionDineroHarness"

// edicion-operaciones-con-dinero (tanda C): arnés de navegador real para la pasada visual del formulario de edición con los
// bloques de dinero, el diálogo del plan y el historial de cambios (ver app/dev-harness/README.md). Sólo existe en desarrollo.
export default function Page() {
  if (process.env.NODE_ENV === "production") notFound()
  return <EdicionDineroHarness />
}

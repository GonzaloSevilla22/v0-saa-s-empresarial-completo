import { notFound } from "next/navigation"
import { BellHarness } from "./BellHarness"

// qa-integral-modulos G5: arnés de navegador real (ver app/dev-harness/README.md).
// Solo existe en desarrollo — en un build de producción la ruta es 404.
export default function Page() {
  if (process.env.NODE_ENV === "production") notFound()
  return <BellHarness />
}

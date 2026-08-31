import { notFound } from "next/navigation"
import { PopoverHarness } from "./PopoverHarness"

// qa-integral-modulos G1: arnés de navegador real (ver app/dev-harness/README.md).
// Solo existe en desarrollo — en un build de producción la ruta es 404.
export default function Page() {
  if (process.env.NODE_ENV === "production") notFound()
  return <PopoverHarness />
}

import { notFound } from "next/navigation"
import { ShellHarness } from "./ShellHarness"

// qa-integral-modulos G2/G13: arnés de navegador real (ver app/dev-harness/README.md).
export default function Page() {
  if (process.env.NODE_ENV === "production") notFound()
  return <ShellHarness />
}

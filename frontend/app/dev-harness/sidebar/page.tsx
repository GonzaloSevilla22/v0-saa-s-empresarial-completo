import { notFound } from "next/navigation"
import { SidebarHarness } from "./SidebarHarness"

// sidebar-menu-grupos: arnés de navegador real del menú lateral agrupado (ver
// app/dev-harness/README.md). Sólo existe en desarrollo.
export default function Page() {
  if (process.env.NODE_ENV === "production") notFound()
  return <SidebarHarness />
}

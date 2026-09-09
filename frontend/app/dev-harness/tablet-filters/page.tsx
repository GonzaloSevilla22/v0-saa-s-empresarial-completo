import { notFound } from "next/navigation"
import { TabletFiltersHarness } from "./TabletFiltersHarness"

// tablet-filtros-cta: arnés de navegador real (ver app/dev-harness/README.md).
// Solo existe en desarrollo — en un build de producción la ruta es 404.
export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ route?: string }>
}) {
  if (process.env.NODE_ENV === "production") notFound()
  const { route } = await searchParams
  const valid = route === "ventas" || route === "gastos" || route === "compras" || route === "clientes"
  return <TabletFiltersHarness route={valid ? route : "ventas"} />
}

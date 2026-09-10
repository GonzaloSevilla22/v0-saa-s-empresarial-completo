import { notFound } from "next/navigation"
import { ExpenseImportHarness } from "./ExpenseImportHarness"

// importador-gastos-transaccional (task 9.6): arnés de navegador real (ver
// app/dev-harness/README.md). Sólo existe en desarrollo.
export default function Page() {
  if (process.env.NODE_ENV === "production") notFound()
  return <ExpenseImportHarness />
}

import { notFound } from "next/navigation"
import { InvitacionesHarness } from "./InvitacionesHarness"

// invitaciones-hardening (task 9.3): arnés de navegador real para la pasada visual del estado de entrega de
// las invitaciones (ver app/dev-harness/README.md). Sólo existe en desarrollo.
export default function Page() {
  if (process.env.NODE_ENV === "production") notFound()
  return <InvitacionesHarness />
}

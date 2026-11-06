import { notFound } from "next/navigation"
import { CopilotoChatHarness } from "./CopilotoChatHarness"

// ia-copilot-v2 (tanda B, task 8.3): arnés de navegador real para la pasada visual de /copiloto-ia
// (ver app/dev-harness/README.md). Sólo existe en desarrollo.
export default function Page() {
  if (process.env.NODE_ENV === "production") notFound()
  return <CopilotoChatHarness />
}

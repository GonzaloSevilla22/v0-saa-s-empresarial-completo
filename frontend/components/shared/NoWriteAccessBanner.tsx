import { Lock } from "lucide-react"

export function NoWriteAccessBanner() {
  return (
    <div className="flex items-center gap-3 rounded-lg border border-yellow-500/30 bg-yellow-500/10 px-4 py-3 text-sm text-yellow-600 dark:text-yellow-400">
      <Lock className="h-4 w-4 shrink-0" />
      <span>Solo lectura — contactá al owner para crear operaciones.</span>
    </div>
  )
}

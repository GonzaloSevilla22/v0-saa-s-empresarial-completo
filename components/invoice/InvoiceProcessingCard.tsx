"use client"

import { Brain, CheckCircle, XCircle, Loader2, Upload, Search } from "lucide-react"
import { Progress } from "@/components/ui/progress"
import { cn } from "@/lib/utils"
import type { OcrStep } from "@/lib/invoice-types"

interface Props {
  step:     OcrStep
  progress: number      // 0–100
  message?: string
  error?:   string | null
}

const STEPS: { key: OcrStep; label: string; icon: React.ElementType }[] = [
  { key: "uploading",   label: "Subiendo",      icon: Upload   },
  { key: "processing",  label: "Leyendo",        icon: Brain    },
  { key: "matching",    label: "Buscando",       icon: Search   },
  { key: "review",      label: "Listo",          icon: CheckCircle },
]

const stepOrder: OcrStep[] = ["uploading", "processing", "matching", "review", "done"]

export function InvoiceProcessingCard({ step, progress, message, error }: Props) {
  if (step === "idle") return null

  const currentIdx = stepOrder.indexOf(step)
  const isError    = step === "error"

  return (
    <div className={cn(
      "rounded-xl border p-5 flex flex-col gap-4 transition-all",
      isError
        ? "border-red-500/30 bg-red-500/5"
        : "border-primary/20 bg-primary/5",
    )}>
      {/* Step indicators */}
      <div className="flex items-center justify-between">
        {STEPS.map((s, i) => {
          const sIdx = stepOrder.indexOf(s.key)
          const done    = !isError && currentIdx > sIdx
          const active  = !isError && currentIdx === sIdx
          const pending = isError || currentIdx < sIdx
          const Icon    = s.icon

          return (
            <div key={s.key} className="flex flex-col items-center gap-1.5">
              <div className={cn(
                "flex h-8 w-8 items-center justify-center rounded-full border-2 transition-all duration-300",
                done    && "border-emerald-500 bg-emerald-500/20 text-emerald-400",
                active  && "border-primary bg-primary/20 text-primary",
                pending && "border-border bg-muted/30 text-muted-foreground/40",
              )}>
                {active && !isError
                  ? <Loader2 className="h-4 w-4 animate-spin" />
                  : done
                  ? <CheckCircle className="h-4 w-4" />
                  : <Icon className="h-4 w-4" />
                }
              </div>
              <span className={cn(
                "text-[10px] font-medium",
                done   && "text-emerald-400",
                active && "text-primary",
                pending && "text-muted-foreground/40",
              )}>
                {s.label}
              </span>
            </div>
          )
        })}
      </div>

      {/* Progress bar */}
      {!isError && (
        <Progress value={progress} className="h-1.5" />
      )}

      {/* Status text */}
      {isError ? (
        <div className="flex items-start gap-2">
          <XCircle className="h-4 w-4 text-red-400 mt-0.5 shrink-0" />
          <div>
            <p className="text-sm font-medium text-red-400">Error al procesar</p>
            {error && <p className="text-xs text-red-400/80 mt-0.5">{error}</p>}
          </div>
        </div>
      ) : (
        message && (
          <p className="text-xs text-muted-foreground text-center animate-pulse">
            {message}
          </p>
        )
      )}
    </div>
  )
}
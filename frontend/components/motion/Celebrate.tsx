"use client"

import type { ReactNode } from "react"
import { AnimatePresence, motion } from "framer-motion"

import { cn } from "@/lib/utils"
import { usePrefersReducedMotion } from "@/hooks/ui/usePrefersReducedMotion"
import { getCelebrateVariants } from "./variants"

export interface CelebrateProps {
  /** Whether the celebration is currently shown. Toggle on/off to mount/unmount it on demand. */
  show: boolean
  children: ReactNode
  className?: string
}

/**
 * On-demand scale-pop feedback for success/hito moments (2D). This is the
 * Fase A micro-animation counterpart of the future 3D burst/celebration
 * scenes (Fase C, `immersive-3d-refresh` design D8) — purely presentational,
 * mounted/unmounted by the caller via `show`, never coupled to handlers,
 * queries or mutations.
 *
 * Spec `visual-design-system`, Requirement "Sistema de micro-animaciones 2D
 * con respeto de reduced-motion" — Scenario "Respeto de prefers-reduced-motion".
 */
export function Celebrate({ show, children, className }: CelebrateProps) {
  const prefersReducedMotion = usePrefersReducedMotion()

  return (
    <AnimatePresence>
      {show && (
        <motion.div
          className={cn(className)}
          initial="hidden"
          animate="visible"
          exit="hidden"
          variants={getCelebrateVariants(prefersReducedMotion)}
        >
          {children}
        </motion.div>
      )}
    </AnimatePresence>
  )
}

"use client"

import type { ReactNode } from "react"
import { motion } from "framer-motion"

import { cn } from "@/lib/utils"
import { usePrefersReducedMotion } from "@/hooks/ui/usePrefersReducedMotion"
import { getFadeInTransition, getFadeInVariants } from "./variants"

export interface FadeInProps {
  children: ReactNode
  /** Delay in seconds before the fade-in starts. Ignored under reduced motion. */
  delay?: number
  className?: string
}

/**
 * Standard fade + subtle slide-up entrance wrapper, tokenized via
 * `lib/motion-tokens.ts` and degraded via `usePrefersReducedMotion`.
 *
 * Spec `visual-design-system`, Requirement "Sistema de micro-animaciones 2D
 * con respeto de reduced-motion" — Scenario "Animación de entrada estándar".
 */
export function FadeIn({ children, delay = 0, className }: FadeInProps) {
  const prefersReducedMotion = usePrefersReducedMotion()

  return (
    <motion.div
      className={cn(className)}
      initial="hidden"
      animate="visible"
      variants={getFadeInVariants(prefersReducedMotion)}
      transition={getFadeInTransition(prefersReducedMotion, delay)}
    >
      {children}
    </motion.div>
  )
}

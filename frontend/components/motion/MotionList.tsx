"use client"

import type { ReactNode } from "react"
import { motion } from "framer-motion"

import { cn } from "@/lib/utils"
import { usePrefersReducedMotion } from "@/hooks/ui/usePrefersReducedMotion"
import { getMotionListContainerVariants, getMotionListItemVariants } from "./variants"

export interface MotionListProps {
  children: ReactNode
  className?: string
  /** Delay in seconds between each child's entrance. Collapses to 0 under reduced motion. */
  staggerDelay?: number
}

/**
 * Container for a staggered list/grid entrance. Wrap each direct child in
 * `MotionListItem`. Tokenized via `lib/motion-tokens.ts` and degraded via
 * `usePrefersReducedMotion` (stagger collapses to 0, items fade without
 * offset).
 *
 * Spec `visual-design-system`, Requirement "Sistema de micro-animaciones 2D
 * con respeto de reduced-motion" — Scenario "Animación de entrada estándar".
 */
export function MotionList({ children, className, staggerDelay = 0.06 }: MotionListProps) {
  const prefersReducedMotion = usePrefersReducedMotion()

  return (
    <motion.div
      className={cn(className)}
      initial="hidden"
      animate="visible"
      variants={getMotionListContainerVariants(prefersReducedMotion, staggerDelay)}
    >
      {children}
    </motion.div>
  )
}

export interface MotionListItemProps {
  children: ReactNode
  className?: string
}

/** A single entry inside a `MotionList`; must be a direct child of it. */
export function MotionListItem({ children, className }: MotionListItemProps) {
  const prefersReducedMotion = usePrefersReducedMotion()

  return (
    <motion.div className={cn(className)} variants={getMotionListItemVariants(prefersReducedMotion)}>
      {children}
    </motion.div>
  )
}

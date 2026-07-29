/**
 * Pure variant+theme → color-palette mapping for
 * `components/three/CelebrationScene.tsx` (tasks 3.5 "venta cerrada" / 3.6
 * "meta alcanzada", design.md D9 / task 3.7 — celebrations are theme-aware
 * too). Same "pure logic separated from the WebGL render" split as
 * `heroSceneTheme.ts` — the scene itself needs a real WebGL context and is
 * verified via browser E2E, not jsdom.
 */

import type { SceneTheme } from "./heroSceneTheme"

export type CelebrationVariant = "sale" | "goal"

/** "Venta cerrada" — same green family as the brand/hero, reads as a familiar success color. */
const SALE_LIGHT = ["#16a34a", "#0d9488", "#22c55e"]
const SALE_DARK = ["#34d399", "#2dd4bf", "#6ee7b7"]

/** "Meta alcanzada" — warm gold/amber, deliberately distinct from "sale" so the two celebrations read as different milestones. */
const GOAL_LIGHT = ["#f59e0b", "#d97706", "#fbbf24"]
const GOAL_DARK = ["#fbbf24", "#fcd34d", "#f59e0b"]

export function getCelebrationColors(variant: CelebrationVariant, theme: SceneTheme): string[] {
  if (variant === "goal") return theme === "dark" ? GOAL_DARK : GOAL_LIGHT
  return theme === "dark" ? SALE_DARK : SALE_LIGHT
}

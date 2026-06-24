/**
 * Idle session timeout — pure configuration module.
 *
 * All threshold logic lives here as a pure function so it is deterministic,
 * DOM-free, and unit-testable without any React/browser setup.
 *
 * Design decision (Design.md §Decision 2):
 *   computeIdleState is the single source of truth for the active/warning/expired
 *   classification. The React hook and cross-tab transport are thin shells around it.
 */

// ── Constants ─────────────────────────────────────────────────────────────────

/** Total inactivity threshold: 20 minutes. Fixed; not configurable at runtime. */
export const IDLE_TIMEOUT_MS = 1_200_000 // 20 * 60 * 1_000

/** How early to show the warning modal before logout: 1 minute. */
export const WARNING_BEFORE_MS = 60_000 // 60 * 1_000

// ── Types ─────────────────────────────────────────────────────────────────────

/** Classification returned by `computeIdleState`. */
export type IdleState = "active" | "warning" | "expired"

/** Configuration passed to `computeIdleState`; defaults mirror the exported constants. */
export interface IdleConfig {
  idleTimeoutMs: number
  warningBeforeMs: number
}

/** Default config object built from the exported constants. */
export const DEFAULT_IDLE_CONFIG: IdleConfig = {
  idleTimeoutMs: IDLE_TIMEOUT_MS,
  warningBeforeMs: WARNING_BEFORE_MS,
}

// ── Pure decision function ────────────────────────────────────────────────────

/**
 * Classifies the current idle state based on time since last activity.
 *
 * Pure: no DOM, no timers, no network. Safe to call in any context.
 *
 * @param lastActivity  Absolute timestamp (ms) of the last recorded user activity.
 * @param now           Current timestamp (ms). Pass `Date.now()` from the caller.
 * @param config        Threshold configuration (defaults to module constants).
 * @returns  `'active'`  — elapsed < warningAt
 *           `'warning'` — warningAt <= elapsed < idleTimeoutMs
 *           `'expired'` — elapsed >= idleTimeoutMs
 */
export function computeIdleState(
  lastActivity: number,
  now: number,
  config: IdleConfig = DEFAULT_IDLE_CONFIG,
): IdleState {
  const elapsed = now - lastActivity
  const warningAt = config.idleTimeoutMs - config.warningBeforeMs

  if (elapsed >= config.idleTimeoutMs) return "expired"
  if (elapsed >= warningAt) return "warning"
  return "active"
}

/**
 * Returns the milliseconds remaining until the idle timeout fires.
 * Always >= 0 (clamps at 0 if already expired).
 */
export function msUntilExpiry(lastActivity: number, now: number, config: IdleConfig = DEFAULT_IDLE_CONFIG): number {
  return Math.max(0, lastActivity + config.idleTimeoutMs - now)
}

/**
 * Returns the milliseconds remaining until the warning window opens.
 * Always >= 0 (clamps at 0 if already in warning or expired).
 */
export function msUntilWarning(lastActivity: number, now: number, config: IdleConfig = DEFAULT_IDLE_CONFIG): number {
  const warningAt = config.idleTimeoutMs - config.warningBeforeMs
  return Math.max(0, lastActivity + warningAt - now)
}

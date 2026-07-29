"use client"

import { Component, type ReactNode } from "react"

export interface SceneErrorBoundaryProps {
  /** Static poster/gradient rendered instead of the broken scene. */
  fallback: ReactNode
  children: ReactNode
  /** Called with the caught error/info — for logging, never for re-throwing. */
  onError?: (error: unknown, info: { componentStack?: string | null }) => void
}

interface SceneErrorBoundaryState {
  hasError: boolean
}

/**
 * Error boundary for 3D scenes (spec `immersive-3d-surfaces`, Requirement
 * "Resiliencia ante fallo de escena"): a scene that fails during render
 * (corrupt state, WebGL context loss surfaced as a thrown error by the scene
 * — see `Lazy3DCanvas`) degrades to `fallback` instead of leaving the
 * surface blank or crashing the rest of the app.
 *
 * Class component because React error boundaries require
 * `getDerivedStateFromError`/`componentDidCatch`, which have no hook
 * equivalent.
 */
export class SceneErrorBoundary extends Component<
  SceneErrorBoundaryProps,
  SceneErrorBoundaryState
> {
  state: SceneErrorBoundaryState = { hasError: false }

  static getDerivedStateFromError(): SceneErrorBoundaryState {
    return { hasError: true }
  }

  componentDidCatch(error: unknown, info: { componentStack?: string | null }): void {
    this.props.onError?.(error, info)
  }

  render(): ReactNode {
    if (this.state.hasError) return this.props.fallback
    return this.props.children
  }
}

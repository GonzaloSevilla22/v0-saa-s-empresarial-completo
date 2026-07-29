"use client"

import { useMemo, useRef } from "react"
import { useTheme } from "next-themes"
import { useFrame, useThree } from "@react-three/fiber"
import type { Mesh } from "three"
import { getHeroSceneColors } from "@/lib/three/heroSceneTheme"

/** Radians/second — slow, ambient rotation (decorative, not distracting). */
const CORE_ROTATION_SPEED = 0.12
const SATELLITE_COUNT = 3
const SATELLITE_ORBIT_RADIUS = 2.2

interface SatelliteConfig {
  key: number
  position: [number, number, number]
  scale: number
}

function buildSatellites(): SatelliteConfig[] {
  return Array.from({ length: SATELLITE_COUNT }, (_, i) => {
    const angle = (i / SATELLITE_COUNT) * Math.PI * 2
    return {
      key: i,
      position: [
        Math.cos(angle) * SATELLITE_ORBIT_RADIUS,
        Math.sin(angle * 1.3) * 0.6,
        Math.sin(angle) * SATELLITE_ORBIT_RADIUS,
      ],
      scale: 0.32 + (i % 2) * 0.12,
    }
  })
}

/**
 * Pilot 3D scene (task 2.9, reused as the landing hero in Fase C task 3.1) —
 * 100% procedural low-poly geometry (icosahedron core + orbiting octahedra),
 * per PO sign-off 2026-07-29 (design.md Open Question 5): no downloaded or
 * commissioned models, no glTF assets, everything built from R3F/three
 * primitives in code.
 *
 * Rendered as the `children` of `Lazy3DCanvas` (`frameloop="demand"`): the
 * continuous slow rotation stays smooth under "demand" mode because every
 * `useFrame` tick calls `invalidate()` itself — R3F's documented pattern for
 * combining `frameloop="demand"` (no wasted frames while idle/off-screen —
 * enforced by `Lazy3DCanvas` unmounting outside the viewport) with a scene
 * that animates every frame while it IS mounted and visible.
 *
 * Theme-aware (design.md D9 / task 3.7): reads `next-themes` via `useTheme()`
 * and re-colors materials through the pure, unit-tested
 * `lib/three/heroSceneTheme.ts` — see __tests__/lib/three/heroSceneTheme.test.ts.
 *
 * Not unit-tested itself (needs a real WebGL context, unavailable in jsdom);
 * verified via browser E2E (task 2.10/3.7 — light/dark, reduced-motion,
 * no-WebGL, mobile).
 */
export default function HeroScene() {
  const { resolvedTheme } = useTheme()
  const colors = useMemo(
    () => getHeroSceneColors(resolvedTheme === "dark" ? "dark" : "light"),
    [resolvedTheme],
  )

  const coreRef = useRef<Mesh>(null)
  const invalidate = useThree((state) => state.invalidate)

  useFrame((_state, delta) => {
    if (coreRef.current) coreRef.current.rotation.y += delta * CORE_ROTATION_SPEED
    invalidate()
  })

  const satellites = useMemo(buildSatellites, [])

  return (
    <>
      <ambientLight intensity={0.6} />
      <directionalLight position={[3, 4, 2]} intensity={1.1} color={colors.primary} />
      <group>
        <mesh ref={coreRef}>
          <icosahedronGeometry args={[1.4, 0]} />
          <meshStandardMaterial
            color={colors.primary}
            emissive={colors.primary}
            emissiveIntensity={colors.emissiveIntensity}
            flatShading
            roughness={0.35}
            metalness={0.1}
          />
        </mesh>
        {satellites.map((satellite) => (
          <mesh key={satellite.key} position={satellite.position} scale={satellite.scale}>
            <octahedronGeometry args={[1, 0]} />
            <meshStandardMaterial
              color={colors.accent}
              emissive={colors.accent}
              emissiveIntensity={colors.emissiveIntensity}
              flatShading
              roughness={0.4}
              metalness={0.1}
            />
          </mesh>
        ))}
      </group>
    </>
  )
}

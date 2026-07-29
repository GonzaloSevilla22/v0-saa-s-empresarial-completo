"use client"

import { useMemo, useRef } from "react"
import { useTheme } from "next-themes"
import { useFrame, useThree } from "@react-three/fiber"
import type { Mesh } from "three"
import { getHeroSceneColors } from "@/lib/three/heroSceneTheme"

/** Radians/second — slower than the hero, this sits behind a form and shouldn't compete for attention. */
const RING_ROTATION_SPEED = 0.08
const RING_COUNT = 3

interface RingConfig {
  key: number
  rotationOffset: [number, number, number]
  radius: number
}

function buildRings(): RingConfig[] {
  return Array.from({ length: RING_COUNT }, (_, i) => ({
    key: i,
    rotationOffset: [i * 0.5, i * 0.9, 0],
    radius: 1.1 + i * 0.55,
  }))
}

/**
 * Login/registro accompaniment scene (task 3.2) — background accent, NOT the
 * focal point (D8: "escena 3D de acompañamiento (lateral/fondo)"). Concentric
 * low-poly torus rings, slow independent rotation — 100% procedural (PO
 * sign-off, same constraint as `HeroScene`). Reuses `getHeroSceneColors` (the
 * SAME tested theme mapping as the hero) rather than a separate palette — one
 * fewer thing to keep in sync, and the login/register accent should read as
 * "the same brand system", not a competing visual.
 *
 * Not unit-tested (needs a real WebGL context) — verified via browser E2E.
 */
export default function AuthScene() {
  const { resolvedTheme } = useTheme()
  const colors = useMemo(
    () => getHeroSceneColors(resolvedTheme === "dark" ? "dark" : "light"),
    [resolvedTheme],
  )

  const ringRefs = useRef<(Mesh | null)[]>([])
  const invalidate = useThree((state) => state.invalidate)

  useFrame((_state, delta) => {
    ringRefs.current.forEach((ring, i) => {
      if (!ring) return
      const direction = i % 2 === 0 ? 1 : -1
      ring.rotation.z += delta * RING_ROTATION_SPEED * direction
      ring.rotation.x += delta * RING_ROTATION_SPEED * 0.4 * direction
    })
    invalidate()
  })

  const rings = useMemo(buildRings, [])

  return (
    <>
      <ambientLight intensity={0.55} />
      <directionalLight position={[2, 3, 4]} intensity={0.9} color={colors.accent} />
      {rings.map((ring, i) => (
        <mesh
          key={ring.key}
          ref={(el) => { ringRefs.current[i] = el }}
          rotation={ring.rotationOffset}
        >
          <torusGeometry args={[ring.radius, 0.05, 6, 24]} />
          <meshStandardMaterial
            color={i % 2 === 0 ? colors.primary : colors.accent}
            emissive={i % 2 === 0 ? colors.primary : colors.accent}
            emissiveIntensity={colors.emissiveIntensity * 0.7}
            flatShading
            roughness={0.4}
            metalness={0.1}
          />
        </mesh>
      ))}
    </>
  )
}

"use client"

import { useMemo, useRef } from "react"
import { useTheme } from "next-themes"
import { useFrame, useThree } from "@react-three/fiber"
import type { Group, Mesh } from "three"
import { getCelebrationColors, type CelebrationVariant } from "@/lib/three/celebrationTheme"

const PARTICLE_COUNT = 14
const BURST_SPEED = 2.4 // units/second, outward
const BURST_DURATION_S = 1.4 // matches Celebration3D's default 1800ms minus a small settle margin
const PARTICLE_SCALE = 0.16

interface Particle {
  key: number
  direction: [number, number, number]
  color: string
}

function buildParticles(colors: string[]): Particle[] {
  return Array.from({ length: PARTICLE_COUNT }, (_, i) => {
    // Even angular spread around the vertical axis, with some vertical variance —
    // reads as an outward "pop" rather than a flat ring.
    const angle = (i / PARTICLE_COUNT) * Math.PI * 2
    const elevation = ((i % 3) - 1) * 0.4 // -0.4 / 0 / 0.4
    return {
      key: i,
      direction: [Math.cos(angle), elevation, Math.sin(angle)],
      color: colors[i % colors.length],
    }
  })
}

/**
 * Procedural burst — small octahedra fly outward from center and fade,
 * matching the low-poly language of `HeroScene`/`AuthScene` (PO sign-off:
 * 100% procedural, no downloaded assets). Self-contained: runs once per
 * mount (the parent `Celebration3D` mounts/unmounts it per celebration), no
 * external replay control needed.
 *
 * Not unit-tested (needs a real WebGL context) — the variant/theme→color
 * mapping is extracted to the pure, tested `lib/three/celebrationTheme.ts`.
 */
export default function CelebrationScene({ variant }: { variant: CelebrationVariant }) {
  const { resolvedTheme } = useTheme()
  const colors = useMemo(
    () => getCelebrationColors(variant, resolvedTheme === "dark" ? "dark" : "light"),
    [variant, resolvedTheme],
  )
  const particles = useMemo(() => buildParticles(colors), [colors])

  const groupRefs = useRef<(Group | null)[]>([])
  const materialRefs = useRef<(Mesh["material"] | null)[]>([])
  const elapsedRef = useRef(0)
  const invalidate = useThree((state) => state.invalidate)

  useFrame((_state, delta) => {
    elapsedRef.current += delta
    const t = Math.min(elapsedRef.current / BURST_DURATION_S, 1)
    const eased = 1 - (1 - t) * (1 - t) // ease-out — fast start, settles near the end

    particles.forEach((particle, i) => {
      const group = groupRefs.current[i]
      if (group) {
        group.position.set(
          particle.direction[0] * BURST_SPEED * eased,
          particle.direction[1] * BURST_SPEED * eased + 0.3, // slight upward drift
          particle.direction[2] * BURST_SPEED * eased,
        )
        group.rotation.y += delta * 3
      }
      const material = materialRefs.current[i] as { opacity?: number } | null
      if (material) material.opacity = 1 - t
    })

    invalidate()
  })

  return (
    <>
      <ambientLight intensity={0.8} />
      <pointLight position={[0, 2, 3]} intensity={1.2} />
      {particles.map((particle, i) => (
        <group key={particle.key} ref={(el) => { groupRefs.current[i] = el }}>
          <mesh scale={PARTICLE_SCALE}>
            <octahedronGeometry args={[1, 0]} />
            <meshStandardMaterial
              ref={(el) => { materialRefs.current[i] = el }}
              color={particle.color}
              emissive={particle.color}
              emissiveIntensity={0.5}
              flatShading
              transparent
              opacity={1}
            />
          </mesh>
        </group>
      ))}
    </>
  )
}

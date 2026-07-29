/**
 * Pure theme → material-color mapping for `components/three/scenes/HeroScene.tsx`
 * (design.md D9 / task 3.7 — "cada escena lee el tema activo... o ajusta
 * luces/fondo/materiales"). Kept pure and separate from the R3F scene
 * component itself so this behavior is unit-testable without a WebGL
 * context — HeroScene's own render output is verified via browser E2E
 * (task 2.10), not jsdom.
 *
 * Colors approximate the app's `--primary`/token green (`hsl(142 71% 45%)`,
 * `app/globals.css`) and its `.dark` counterpart, without importing the CSS
 * pipeline into a WebGL material (Three materials need JS color values, not
 * `var(--token)`; same "duplicated source of truth" trade-off already made by
 * `lib/motion-tokens.ts` for Framer Motion).
 */

export type SceneTheme = "light" | "dark"

export interface HeroSceneColors {
  /** Core material color (mirrors `--primary`). */
  primary: string
  /** Secondary/orbiting elements color. */
  accent: string
  /** `meshStandardMaterial.emissiveIntensity` — how much the material "glows" on its own, independent of scene lights. */
  emissiveIntensity: number
}

const LIGHT_COLORS: HeroSceneColors = {
  primary: "#16a34a", // ~hsl(142 71% 45%), --primary in light theme
  accent: "#0d9488",
  emissiveIntensity: 0.15,
}

const DARK_COLORS: HeroSceneColors = {
  primary: "#34d399", // brighter/lighter green — --primary equivalent against a dark backdrop
  accent: "#2dd4bf",
  emissiveIntensity: 0.45, // dark theme needs more self-glow to read against a near-black background
}

export function getHeroSceneColors(theme: SceneTheme): HeroSceneColors {
  return theme === "dark" ? DARK_COLORS : LIGHT_COLORS
}

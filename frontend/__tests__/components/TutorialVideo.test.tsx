/**
 * Render tests for TutorialVideo — the shared facade player used both in the
 * landing "Aprendé a usar ALIADATA" section and the dashboard's contextual
 * "Ver tutorial" modal.
 *
 * Cycle: RED → GREEN → TRIANGULATE
 */

import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"

vi.mock("@next/third-parties/google", () => ({
  YouTubeEmbed: (props: { videoid: string; params?: string; height?: number; width?: number }) => (
    <div
      data-testid="youtube-embed"
      data-videoid={props.videoid}
      data-params={props.params}
    />
  ),
}))

import { TutorialVideo } from "@/components/shared/TutorialVideo"

describe("TutorialVideo", () => {
  // ── RED → GREEN: renders the embed with the given id ──────────────────
  it("renders the YouTubeEmbed with the given youtubeVideoId", () => {
    render(<TutorialVideo youtubeVideoId="dQw4w9WgXcQ" />)
    const embed = screen.getByTestId("youtube-embed")
    expect(embed).toHaveAttribute("data-videoid", "dQw4w9WgXcQ")
  })

  // ── TRIANGULATE: always passes rel=0, regardless of the id ────────────
  it("always passes params=\"rel=0\" to limit related-video suggestions to the own channel", () => {
    render(<TutorialVideo youtubeVideoId="abc123XYZ99" />)
    const embed = screen.getByTestId("youtube-embed")
    expect(embed).toHaveAttribute("data-params", "rel=0")
  })

  // ── TRIANGULATE: 16:9 aspect-ratio container (Radix padding-bottom trick) ──
  it("wraps the embed in a 16:9 aspect-ratio container", () => {
    const { container } = render(<TutorialVideo youtubeVideoId="dQw4w9WgXcQ" />)
    const aspectWrapper = container.querySelector<HTMLElement>("[data-radix-aspect-ratio-wrapper]")
    expect(aspectWrapper).not.toBeNull()
    // 16:9 → paddingBottom = 100 / (16/9) = 56.25%
    expect(aspectWrapper?.style.paddingBottom).toBe("56.25%")
  })
})

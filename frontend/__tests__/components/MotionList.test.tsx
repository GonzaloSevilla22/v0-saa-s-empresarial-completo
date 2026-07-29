/**
 * Tests for the `MotionList`/`MotionListItem` motion wrappers
 * (components/motion/MotionList.tsx), task 1.5/1.6/1.7 of
 * `v4-visual-3d-refresh` Fase A.
 *
 * Same real-wiring approach as FadeIn.test.tsx: real `usePrefersReducedMotion`
 * hook (matchMedia stubbed), real variants from `components/motion/variants.ts`.
 * Assertions target the settled state via `waitFor` for the same reason
 * documented there and in variants.ts's GOTCHA comment (the hook resolves
 * `false` synchronously on the first frame, then corrects async). The
 * timeout is generous (2s): jsdom's rAF polyfill runs noticeably slower than
 * a real display, so a 120-200ms token duration can take up to ~1s of wall
 * clock to fully settle in this test environment.
 *
 * `MotionListItem` renders its children as a direct child (no wrapping
 * element), so `screen.getByText(...)` itself IS the item's animated node —
 * `.parentElement` from there is the `MotionList` container, not the item.
 *
 * Cycle: RED (MotionList.tsx doesn't exist yet) → GREEN → TRIANGULATE (full
 * motion vs reduced motion, stagger present vs collapsed) → REFACTOR.
 */

import { describe, it, expect } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import { MotionList, MotionListItem } from "@/components/motion/MotionList"

function installMatchMediaStub(matches: boolean) {
  window.matchMedia = (query: string): MediaQueryList =>
    ({
      matches,
      media: query,
      onchange: null,
      addEventListener: () => {},
      removeEventListener: () => {},
      addListener: () => {},
      removeListener: () => {},
      dispatchEvent: () => false,
    }) as MediaQueryList
}

describe("MotionList / MotionListItem", () => {
  // ── RED/GREEN: happy path — renders every item, items settle visible ──
  it("renders every MotionListItem and settles them fully visible when motion is enabled", async () => {
    installMatchMediaStub(false)
    render(
      <MotionList>
        <MotionListItem>uno</MotionListItem>
        <MotionListItem>dos</MotionListItem>
        <MotionListItem>tres</MotionListItem>
      </MotionList>
    )

    expect(screen.getByText("uno")).toBeInTheDocument()
    expect(screen.getByText("dos")).toBeInTheDocument()
    expect(screen.getByText("tres")).toBeInTheDocument()

    await waitFor(
      () => expect(screen.getByText("uno").style.opacity).toBe("1"),
      { timeout: 2000 }
    )
  })

  // ── TRIANGULATE: edge case — reduced motion, items settle with no offset ──
  it("settles every item fully visible with no leftover transform under reduced motion", async () => {
    installMatchMediaStub(true)
    render(
      <MotionList>
        <MotionListItem>a</MotionListItem>
        <MotionListItem>b</MotionListItem>
      </MotionList>
    )

    await waitFor(
      () => {
        expect(screen.getByText("a").style.opacity).toBe("1")
        expect(screen.getByText("b").style.opacity).toBe("1")
      },
      { timeout: 2000 }
    )

    // Regression guard (same gotcha as FadeIn): no residual translateY once
    // reduced-motion is confirmed.
    expect(screen.getByText("a").style.transform).not.toContain("translateY")
    expect(screen.getByText("b").style.transform).not.toContain("translateY")
  })

  it("forwards className to the list container and each item", () => {
    installMatchMediaStub(false)
    render(
      <MotionList className="list-class">
        <MotionListItem className="item-class">solo</MotionListItem>
      </MotionList>
    )

    const item = screen.getByText("solo")
    expect(item.className).toContain("item-class")
    expect(item.parentElement?.className).toContain("list-class")
  })
})

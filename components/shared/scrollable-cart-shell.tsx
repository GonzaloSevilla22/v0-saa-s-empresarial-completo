"use client"

/**
 * ScrollableCartShell — enterprise ERP/POS cart layout primitive.
 *
 * Three fixed zones:
 *  ┌──────────────────────────────────────────────┐
 *  │  HEADER  (shrink-0, never scrolls)           │  ← form fields + product adder
 *  ├──────────────────────────────────────────────┤
 *  │  LIST    (flex-1, scrolls internally only)   │  ← cart items
 *  ├──────────────────────────────────────────────┤
 *  │  FOOTER  (shrink-0, always visible)          │  ← total + submit
 *  └──────────────────────────────────────────────┘
 *
 * Rules:
 *  - Only LIST zone scrolls. HEADER and FOOTER are always visible.
 *  - max-h uses `dvh` (dynamic viewport height) so mobile browser chrome
 *    doesn't cover content when the address bar collapses/expands.
 *  - Scrollbar is styled to be subtle (1.5px, rounded, border-colour).
 *  - Works inside Shadcn <DialogContent> without double-scroll.
 *
 * Usage:
 *   <form onSubmit={...}>
 *     <ScrollableCartShell
 *       hasItems={cartItems.length > 0}
 *       listContent={<CartItemList ... />}
 *       footerContent={<><TotalRow /><SubmitButton /></>}
 *     >
 *       {/* header: meta fields + product adder *\/}
 *     </ScrollableCartShell>
 *   </form>
 */

import { cn } from "@/lib/utils"

interface ScrollableCartShellProps {
  /** Fixed top zone: form meta-fields + product-adder. Never scrolls. */
  children: React.ReactNode
  /** Scrollable middle zone: the cart item list. */
  listContent?: React.ReactNode
  /** Fixed bottom zone: total summary + submit button. Always visible. */
  footerContent: React.ReactNode
  /** Show/hide the list zone (avoids layout shift when cart is empty). */
  hasItems: boolean
  className?: string
}

export function ScrollableCartShell({
  children,
  listContent,
  footerContent,
  hasItems,
  className,
}: ScrollableCartShellProps) {
  return (
    <div
      className={cn(
        // ── Outer container ──────────────────────────────────────────────
        "flex flex-col",
        // Cap total height so the dialog never overflows the viewport.
        // dvh = dynamic viewport height (accounts for mobile browser chrome).
        // Fallback to vh for browsers without dvh support.
        "max-h-[calc(100dvh-8rem)] sm:max-h-[80vh]",
        // overflow-hidden stops the parent dialog from adding its own scrollbar.
        "overflow-hidden",
        className,
      )}
    >
      {/* ── HEADER ZONE ─────────────────────────────────────────────────── */}
      {/* shrink-0 prevents this zone from compressing when the list is tall. */}
      <div className="shrink-0 flex flex-col gap-4">
        {children}
      </div>

      {/* ── LIST ZONE ───────────────────────────────────────────────────── */}
      {/* Only this zone scrolls. The scroll container has:                  */}
      {/*  - border-y: visual separation from header/footer                  */}
      {/*  - mt-4: breathing room from the header                            */}
      {/*  - max-h-[40vh]: prevents the list from consuming the full dialog  */}
      {/*  - Custom thin scrollbar for an enterprise look                    */}
      {hasItems && listContent && (
        <div
          className={cn(
            "mt-4",
            "overflow-y-auto",
            // Responsive cap: 40 vh leaves comfortable room for header + footer
            // on desktops. On short screens (landscape mobile) 35vh is safer.
            "max-h-[40vh] landscape:max-h-[35vh]",
            // Visual separation
            "border-y border-border",
            // Subtle enterprise scrollbar
            "[&::-webkit-scrollbar]:w-1.5",
            "[&::-webkit-scrollbar-thumb]:rounded-full",
            "[&::-webkit-scrollbar-thumb]:bg-border",
            "[&::-webkit-scrollbar-track]:bg-transparent",
            // Firefox
            "scrollbar-thin scrollbar-thumb-border scrollbar-track-transparent",
          )}
        >
          {listContent}
        </div>
      )}

      {/* ── FOOTER ZONE ─────────────────────────────────────────────────── */}
      {/* shrink-0 keeps footer visible regardless of list height.           */}
      <div
        className={cn(
          "shrink-0 flex flex-col gap-3",
          // Top spacing only when list is present (border-y already separates)
          hasItems ? "mt-4" : "mt-4",
        )}
      >
        {footerContent}
      </div>
    </div>
  )
}

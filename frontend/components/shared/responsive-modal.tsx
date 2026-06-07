"use client"

import { useIsMobile } from "@/hooks/use-is-mobile"
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet"

interface ResponsiveModalProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  title: string
  children: React.ReactNode
}

/**
 * Desktop (sm+): centered Dialog with max-w-xl.
 * Mobile (<sm):  Sheet sliding up from the bottom, full-width, rounded top corners.
 *
 * The wider desktop dialog (xl vs the previous lg) gives the product picker
 * ~200px more horizontal space — enough to show parentName + variant + price
 * without aggressive truncation.
 */
export function ResponsiveModal({
  open,
  onOpenChange,
  title,
  children,
}: ResponsiveModalProps) {
  const isMobile = useIsMobile()

  if (isMobile) {
    return (
      <Sheet open={open} onOpenChange={onOpenChange}>
        <SheetContent
          side="bottom"
          className="bg-card border-border rounded-t-2xl px-4 pt-4 pb-6 overflow-hidden flex flex-col max-h-[95dvh]"
        >
          <SheetHeader className="pb-3 shrink-0">
            <SheetTitle className="text-card-foreground text-left">{title}</SheetTitle>
          </SheetHeader>
          {children}
        </SheetContent>
      </Sheet>
    )
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border overflow-hidden sm:max-w-xl">
        <DialogHeader>
          <DialogTitle className="text-card-foreground">{title}</DialogTitle>
        </DialogHeader>
        {children}
      </DialogContent>
    </Dialog>
  )
}

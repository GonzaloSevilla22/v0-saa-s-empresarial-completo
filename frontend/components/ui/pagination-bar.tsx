"use client"

import { Button } from "@/components/ui/button"
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select"
import {
  ChevronLeft, ChevronRight, ChevronsLeft, ChevronsRight,
} from "lucide-react"
import { PAGE_SIZE_OPTIONS, type PageSizeOption, type PaginationMeta } from "@/lib/pagination-utils"

interface PaginationBarProps {
  meta:          PaginationMeta
  onPageChange:  (page: number) => void
  onSizeChange:  (size: PageSizeOption) => void
  loading?:      boolean
  /** Singular label for the records, e.g. "ventas", "gastos". */
  label?:        string
}

export function PaginationBar({
  meta,
  onPageChange,
  onSizeChange,
  loading,
  label = "registros",
}: PaginationBarProps) {
  const { page, pageSize, totalCount, pageCount, from, to } = meta
  const disabled = loading || totalCount === 0
  const atFirst  = page === 0
  const atLast   = page >= pageCount - 1

  return (
    <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between text-sm text-muted-foreground select-none">

      {/* Left — count + page size */}
      <div className="flex items-center gap-3">
        <span className="tabular-nums text-xs">
          {totalCount === 0
            ? `0 ${label}`
            : `${from}–${to} de ${totalCount} ${label}`}
        </span>

        <div className="flex items-center gap-1.5">
          <span className="text-xs">Filas:</span>
          <Select
            value={String(pageSize)}
            onValueChange={(v) => onSizeChange(Number(v) as PageSizeOption)}
            disabled={loading}
          >
            <SelectTrigger className="h-7 w-[4.5rem] text-xs border-border bg-background px-2">
              <SelectValue />
            </SelectTrigger>
            <SelectContent className="bg-popover border-border min-w-0">
              {PAGE_SIZE_OPTIONS.map((s) => (
                <SelectItem key={s} value={String(s)} className="text-xs">
                  {s}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      </div>

      {/* Right — navigation */}
      <div className="flex items-center gap-1">
        <Button
          variant="outline" size="icon"
          className="h-7 w-7 border-border"
          disabled={disabled || atFirst}
          onClick={() => onPageChange(0)}
          aria-label="Primera página"
        >
          <ChevronsLeft className="h-3.5 w-3.5" />
        </Button>

        <Button
          variant="outline" size="icon"
          className="h-7 w-7 border-border"
          disabled={disabled || atFirst}
          onClick={() => onPageChange(page - 1)}
          aria-label="Página anterior"
        >
          <ChevronLeft className="h-3.5 w-3.5" />
        </Button>

        <span className="px-2 text-xs text-foreground tabular-nums min-w-[72px] text-center">
          {totalCount === 0 ? "–" : `${page + 1} / ${pageCount}`}
        </span>

        <Button
          variant="outline" size="icon"
          className="h-7 w-7 border-border"
          disabled={disabled || atLast}
          onClick={() => onPageChange(page + 1)}
          aria-label="Página siguiente"
        >
          <ChevronRight className="h-3.5 w-3.5" />
        </Button>

        <Button
          variant="outline" size="icon"
          className="h-7 w-7 border-border"
          disabled={disabled || atLast}
          onClick={() => onPageChange(pageCount - 1)}
          aria-label="Última página"
        >
          <ChevronsRight className="h-3.5 w-3.5" />
        </Button>
      </div>
    </div>
  )
}

"use client"

import { Fragment, useState, useMemo, useCallback } from "react"
import {
  ChevronRight, ChevronDown, Plus, Search, Download,
  Pencil, Trash2, Package, GitBranch,
} from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Badge } from "@/components/ui/badge"
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from "@/components/ui/table"
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog"
import { StockSemaphore } from "@/components/stock/stock-semaphore"
import { formatMoney } from "@/lib/format"
import { exportToCSV } from "@/lib/excel"
import type { Product } from "@/lib/types"
import { toast } from "sonner"
import { cn } from "@/lib/utils"

// ─── Types ────────────────────────────────────────────────────────────────────

interface ProductGroup {
  parent: Product
  children: Product[]
}

interface ProductCatalogProps {
  products: Product[]
  onAdd: () => void
  /** Open the new-product form pre-filled with this parent's id */
  onAddVariant: (parent: Product) => void
  onEdit: (product: Product) => void
  onDelete: (id: string) => Promise<void>
  isAtLimit: boolean
}

// ─── Standalone sub-component (outside ProductCatalog to avoid re-mounts) ────

interface DeleteDialogProps {
  id: string
  label: string
  childCount?: number
  onConfirm: (id: string) => void
  isDeleting: boolean
}

function DeleteDialog({ id, label, childCount = 0, onConfirm, isDeleting }: DeleteDialogProps) {
  return (
    <AlertDialog>
      <AlertDialogTrigger asChild>
        <Button
          variant="ghost"
          size="icon"
          className="h-7 w-7 text-muted-foreground hover:text-destructive"
          disabled={isDeleting}
        >
          <Trash2 className="h-3.5 w-3.5" />
        </Button>
      </AlertDialogTrigger>
      <AlertDialogContent className="bg-card border-border">
        <AlertDialogHeader>
          <AlertDialogTitle className="text-card-foreground">
            Confirmar eliminación
          </AlertDialogTitle>
          <AlertDialogDescription>
            {childCount > 0
              ? `"${label}" tiene ${childCount} variante${childCount > 1 ? "s" : ""}. Al eliminar el producto padre, las variantes quedarán como productos independientes. Esta acción no se puede deshacer.`
              : `¿Eliminar "${label}"? Esta acción no se puede deshacer.`}
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel className="border-border text-foreground">
            Cancelar
          </AlertDialogCancel>
          <AlertDialogAction
            onClick={() => onConfirm(id)}
            disabled={isDeleting}
            className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
          >
            {isDeleting ? "Eliminando…" : "Eliminar"}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function groupStock(g: ProductGroup): number {
  return g.children.reduce((s, c) => s + c.stock, 0)
}

function groupMinStock(g: ProductGroup): number {
  return g.children.reduce((s, c) => s + c.minStock, 0)
}

function groupPriceLabel(g: ProductGroup): string {
  if (g.children.length === 0) return formatMoney(g.parent.price)
  const prices = g.children.map((c) => c.price)
  const min = Math.min(...prices)
  const max = Math.max(...prices)
  return min === max ? formatMoney(min) : `desde ${formatMoney(min)}`
}

// ─── Main component ───────────────────────────────────────────────────────────

export function ProductCatalog({
  products,
  onAdd,
  onAddVariant,
  onEdit,
  onDelete,
  isAtLimit,
}: ProductCatalogProps) {
  const [search, setSearch] = useState("")
  const [expandedIds, setExpandedIds] = useState<Set<string>>(new Set())
  const [deletingId, setDeletingId] = useState<string | null>(null)

  // ── Group products ─────────────────────────────────────────────────────────
  const { groups, standalones } = useMemo(() => {
    const childrenByParent = new Map<string, Product[]>()

    for (const p of products) {
      if (p.parentId) {
        const arr = childrenByParent.get(p.parentId) ?? []
        arr.push(p)
        childrenByParent.set(p.parentId, arr)
      }
    }

    const groups: ProductGroup[] = []
    const standalones: Product[] = []

    for (const p of products) {
      if (p.parentId) continue // handled as child
      const children = childrenByParent.get(p.id) ?? []
      if (children.length > 0) {
        groups.push({ parent: p, children })
      } else {
        standalones.push(p)
      }
    }

    return { groups, standalones }
  }, [products])

  // ── Filter + auto-expand when searching ────────────────────────────────────
  const { filteredGroups, filteredStandalones, autoExpanded } = useMemo(() => {
    if (!search.trim()) {
      return {
        filteredGroups: groups,
        filteredStandalones: standalones,
        autoExpanded: new Set<string>(),
      }
    }

    const q = search.toLowerCase()
    const autoExpanded = new Set<string>()

    const filteredGroups = groups
      .map((g) => {
        const parentHit =
          g.parent.name.toLowerCase().includes(q) ||
          (g.parent.category ?? "").toLowerCase().includes(q) ||
          (g.parent.barcode ?? "").toLowerCase().includes(q)

        const matchingChildren = g.children.filter(
          (c) =>
            c.name.toLowerCase().includes(q) ||
            (c.barcode ?? "").toLowerCase().includes(q),
        )

        if (!parentHit && matchingChildren.length === 0) return null

        autoExpanded.add(g.parent.id)
        return { parent: g.parent, children: parentHit ? g.children : matchingChildren }
      })
      .filter(Boolean) as ProductGroup[]

    const filteredStandalones = standalones.filter(
      (p) =>
        p.name.toLowerCase().includes(q) ||
        (p.category ?? "").toLowerCase().includes(q) ||
        (p.barcode ?? "").toLowerCase().includes(q),
    )

    return { filteredGroups, filteredStandalones, autoExpanded }
  }, [groups, standalones, search])

  // ── Expand toggle ─────────────────────────────────────────────────────────
  function toggleExpand(id: string) {
    setExpandedIds((prev) => {
      const next = new Set(prev)
      next.has(id) ? next.delete(id) : next.add(id)
      return next
    })
  }

  function isExpanded(parentId: string) {
    return expandedIds.has(parentId) || autoExpanded.has(parentId)
  }

  // ── Delete with loading guard ──────────────────────────────────────────────
  const handleDelete = useCallback(
    async (id: string) => {
      setDeletingId(id)
      try {
        await onDelete(id)
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : "Error al eliminar"
        toast.error(msg)
      } finally {
        setDeletingId(null)
      }
    },
    [onDelete],
  )

  // ── Export to CSV ─────────────────────────────────────────────────────────
  function handleExport() {
    const rows: Record<string, unknown>[] = []

    for (const g of groups) {
      rows.push({
        tipo: "Padre",
        nombre: g.parent.name,
        categoria: g.parent.category ?? "",
        precio: "",
        costo: "",
        margen: "",
        stock: groupStock(g),
        stock_minimo: groupMinStock(g),
        codigo: g.parent.barcode ?? "",
        padre: "",
      })
      for (const c of g.children) {
        rows.push({
          tipo: "Variante",
          nombre: c.name,
          categoria: c.category ?? "",
          precio: c.price,
          costo: c.cost,
          margen: c.margin,
          stock: c.stock,
          stock_minimo: c.minStock,
          codigo: c.barcode ?? "",
          padre: g.parent.name,
        })
      }
    }

    for (const p of standalones) {
      rows.push({
        tipo: "Producto",
        nombre: p.name,
        categoria: p.category ?? "",
        precio: p.price,
        costo: p.cost,
        margen: p.margin,
        stock: p.stock,
        stock_minimo: p.minStock,
        codigo: p.barcode ?? "",
        padre: "",
      })
    }

    exportToCSV(
      rows,
      [
        { key: "tipo",         header: "Tipo"           },
        { key: "nombre",       header: "Nombre"         },
        { key: "categoria",    header: "Categoría"      },
        { key: "precio",       header: "Precio"         },
        { key: "costo",        header: "Costo"          },
        { key: "margen",       header: "Margen %"       },
        { key: "stock",        header: "Stock"          },
        { key: "stock_minimo", header: "Stock mínimo"   },
        { key: "codigo",       header: "Código"         },
        { key: "padre",        header: "Producto padre" },
      ],
      "productos",
    )
    toast.success(`Exportados ${rows.length} registros`)
  }

  const totalProducts = products.length

  // ── Render ────────────────────────────────────────────────────────────────
  return (
    <div className="flex flex-col gap-4">
      {/* Toolbar */}
      <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <div className="relative w-full sm:w-64">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            placeholder="Buscar productos…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="pl-9 bg-background border-border text-foreground"
          />
        </div>

        <div className="flex items-center gap-2">
          <Button
            variant="outline"
            size="sm"
            className="border-border text-foreground"
            onClick={handleExport}
          >
            <Download className="h-4 w-4 mr-1" />
            Exportar
          </Button>

          {!isAtLimit && (
            <Button size="sm" onClick={onAdd}>
              <Plus className="h-4 w-4 mr-1" />
              Nuevo producto
            </Button>
          )}
        </div>
      </div>

      {/* ── Mobile card list (sm:hidden) ─────────────────────────────────── */}
      <div className="sm:hidden flex flex-col gap-2">
        {filteredGroups.length === 0 && filteredStandalones.length === 0 ? (
          <div className="rounded-lg border border-border bg-card h-24 flex items-center justify-center text-muted-foreground text-sm">
            {search ? "No se encontraron productos con ese criterio" : "No hay productos. Creá el primero."}
          </div>
        ) : (
          <>
            {/* Product groups */}
            {filteredGroups.map((g) => {
              const expanded = isExpanded(g.parent.id)
              const stock = groupStock(g)
              const minStock = groupMinStock(g)

              return (
                <div key={g.parent.id} className="flex flex-col gap-1">
                  {/* Parent card */}
                  <div className="rounded-lg border border-border bg-card p-3 flex flex-col gap-2">
                    {/* Top row: name + semaphore */}
                    <div className="flex items-start justify-between gap-2">
                      <div className="min-w-0">
                        <div className="flex items-center gap-1.5">
                          <button
                            onClick={() => toggleExpand(g.parent.id)}
                            className="text-muted-foreground hover:text-foreground"
                          >
                            {expanded ? (
                              <ChevronDown className="h-4 w-4" />
                            ) : (
                              <ChevronRight className="h-4 w-4" />
                            )}
                          </button>
                          <span className="font-semibold text-sm text-foreground truncate">{g.parent.name}</span>
                        </div>
                        <div className="flex items-center gap-1.5 pl-5">
                          <GitBranch className="h-3 w-3 text-primary" />
                          <span className="text-[11px] text-primary font-medium">
                            {g.children.length} {g.children.length === 1 ? "variante" : "variantes"}
                          </span>
                        </div>
                      </div>
                      <StockSemaphore stock={stock} minStock={minStock} size="sm" />
                    </div>

                    {/* Middle row: category + price + stock count */}
                    <div className="flex items-center justify-between gap-2 pl-5">
                      <Badge variant="outline" className="text-xs border-border text-muted-foreground">
                        {g.parent.category}
                      </Badge>
                      <div className="flex items-center gap-2">
                        <span className="text-xs text-muted-foreground">{groupPriceLabel(g)}</span>
                        <span className="text-xs text-muted-foreground">{stock} uds</span>
                      </div>
                    </div>

                    {/* Actions */}
                    <div className="flex items-center justify-end gap-1 pt-1 border-t border-border">
                      <Button
                        variant="ghost"
                        size="sm"
                        className="h-7 px-2 text-xs text-primary hover:text-primary hover:bg-primary/10"
                        onClick={() => onAddVariant(g.parent)}
                      >
                        <Plus className="h-3 w-3 mr-0.5" />
                        Variante
                      </Button>
                      <Button
                        variant="ghost"
                        size="icon"
                        className="h-8 w-8 text-muted-foreground hover:text-primary"
                        onClick={() => onEdit(g.parent)}
                      >
                        <Pencil className="h-3.5 w-3.5" />
                      </Button>
                      <DeleteDialog
                        id={g.parent.id}
                        label={g.parent.name}
                        childCount={g.children.length}
                        onConfirm={handleDelete}
                        isDeleting={deletingId === g.parent.id}
                      />
                    </div>
                  </div>

                  {/* Variant cards (expanded) */}
                  {expanded && g.children.map((child) => (
                    <div
                      key={child.id}
                      className="rounded-lg border border-border bg-accent/10 p-3 ml-4 flex flex-col gap-2"
                    >
                      <div className="flex items-start justify-between gap-2">
                        <div className="min-w-0">
                          <span className="text-sm text-foreground font-medium truncate block">{child.name}</span>
                          {child.barcode && (
                            <code className="text-[10px] bg-muted px-1 rounded text-muted-foreground">{child.barcode}</code>
                          )}
                        </div>
                        <StockSemaphore stock={child.stock} minStock={child.minStock} size="sm" />
                      </div>
                      <div className="flex items-center justify-between text-xs">
                        <span className="text-emerald-400 font-medium">{formatMoney(child.price)}</span>
                        <span className={cn(
                          "font-medium",
                          child.margin >= 50 ? "text-emerald-400" : child.margin >= 30 ? "text-yellow-400" : "text-red-400"
                        )}>
                          {child.margin}% margen
                        </span>
                        <span className="text-muted-foreground">{child.stock} uds</span>
                      </div>
                      <div className="flex items-center justify-end gap-1 pt-1 border-t border-border">
                        <Button
                          variant="ghost"
                          size="icon"
                          className="h-8 w-8 text-muted-foreground hover:text-primary"
                          onClick={() => onEdit(child)}
                        >
                          <Pencil className="h-3.5 w-3.5" />
                        </Button>
                        <DeleteDialog
                          id={child.id}
                          label={child.name}
                          onConfirm={handleDelete}
                          isDeleting={deletingId === child.id}
                        />
                      </div>
                    </div>
                  ))}
                </div>
              )
            })}

            {/* Standalone products */}
            {filteredStandalones.map((p) => (
              <div key={p.id} className="rounded-lg border border-border bg-card p-3 flex flex-col gap-2">
                <div className="flex items-start justify-between gap-2">
                  <div className="min-w-0">
                    <span className="font-medium text-sm text-foreground truncate block">{p.name}</span>
                    {p.barcode && (
                      <code className="text-[10px] bg-muted px-1 rounded text-muted-foreground">{p.barcode}</code>
                    )}
                  </div>
                  <StockSemaphore stock={p.stock} minStock={p.minStock} size="sm" />
                </div>
                <div className="flex items-center justify-between gap-2">
                  <Badge variant="outline" className="text-xs border-border text-muted-foreground">
                    {p.category}
                  </Badge>
                  <div className="flex items-center gap-2 text-xs">
                    <span className="text-emerald-400 font-medium">{formatMoney(p.price)}</span>
                    <span className={cn(
                      "font-medium",
                      p.margin >= 50 ? "text-emerald-400" : p.margin >= 30 ? "text-yellow-400" : "text-red-400"
                    )}>
                      {p.margin}%
                    </span>
                    <span className="text-muted-foreground">{p.stock} uds</span>
                  </div>
                </div>
                <div className="flex items-center justify-end gap-1 pt-1 border-t border-border">
                  <Button
                    variant="ghost"
                    size="sm"
                    className="h-7 px-2 text-xs text-muted-foreground hover:text-primary hover:bg-primary/10"
                    onClick={() => onAddVariant(p)}
                  >
                    <Plus className="h-3 w-3 mr-0.5" />
                    Variante
                  </Button>
                  <Button
                    variant="ghost"
                    size="icon"
                    className="h-8 w-8 text-muted-foreground hover:text-primary"
                    onClick={() => onEdit(p)}
                  >
                    <Pencil className="h-3.5 w-3.5" />
                  </Button>
                  <DeleteDialog
                    id={p.id}
                    label={p.name}
                    onConfirm={handleDelete}
                    isDeleting={deletingId === p.id}
                  />
                </div>
              </div>
            ))}
          </>
        )}
      </div>

      {/* ── Desktop table (hidden on mobile) ─────────────────────────────── */}
      <div className="hidden sm:block rounded-lg border border-border overflow-hidden">
        <div className="overflow-x-auto">
          <Table>
            <TableHeader>
              <TableRow className="border-border hover:bg-transparent">
                <TableHead className="w-10" />
                <TableHead className="text-muted-foreground text-xs font-medium uppercase tracking-wider">
                  Producto
                </TableHead>
                <TableHead className="text-muted-foreground text-xs font-medium uppercase tracking-wider">
                  Categoría
                </TableHead>
                <TableHead className="text-muted-foreground text-xs font-medium uppercase tracking-wider">
                  Precio
                </TableHead>
                <TableHead className="text-muted-foreground text-xs font-medium uppercase tracking-wider">
                  Margen
                </TableHead>
                <TableHead className="text-muted-foreground text-xs font-medium uppercase tracking-wider">
                  Stock
                </TableHead>
                <TableHead className="text-muted-foreground text-xs font-medium uppercase tracking-wider">
                  Estado
                </TableHead>
                <TableHead className="w-36" />
              </TableRow>
            </TableHeader>

            <TableBody>
              {/* Empty state */}
              {filteredGroups.length === 0 && filteredStandalones.length === 0 && (
                <TableRow>
                  <TableCell
                    colSpan={8}
                    className="h-32 text-center text-muted-foreground"
                  >
                    {search
                      ? "No se encontraron productos con ese criterio"
                      : "No hay productos. Creá el primero."}
                  </TableCell>
                </TableRow>
              )}

              {/* Product groups — parent + variants */}
              {filteredGroups.map((g) => {
                const expanded = isExpanded(g.parent.id)
                const stock = groupStock(g)
                const minStock = groupMinStock(g)

                return (
                  // Fragment with key to avoid "missing key" warning in React
                  <Fragment key={g.parent.id}>
                    {/* ── Parent row ── */}
                    <TableRow
                      className="border-border hover:bg-accent/50 cursor-pointer"
                      onClick={() => toggleExpand(g.parent.id)}
                    >
                      {/* Expand toggle */}
                      <TableCell>
                        <Button
                          variant="ghost"
                          size="icon"
                          className="h-6 w-6 text-muted-foreground hover:text-foreground"
                          onClick={(e) => {
                            e.stopPropagation()
                            toggleExpand(g.parent.id)
                          }}
                        >
                          {expanded ? (
                            <ChevronDown className="h-4 w-4" />
                          ) : (
                            <ChevronRight className="h-4 w-4" />
                          )}
                        </Button>
                      </TableCell>

                      {/* Name + variant count */}
                      <TableCell>
                        <div className="flex flex-col gap-0.5">
                          <span className="font-semibold text-foreground">
                            {g.parent.name}
                          </span>
                          <div className="flex items-center gap-1.5">
                            <GitBranch className="h-3 w-3 text-primary" />
                            <span className="text-[11px] text-primary font-medium">
                              {g.children.length}{" "}
                              {g.children.length === 1 ? "variante" : "variantes"}
                            </span>
                          </div>
                        </div>
                      </TableCell>

                      {/* Category */}
                      <TableCell>
                        <Badge
                          variant="outline"
                          className="text-xs border-border text-muted-foreground"
                        >
                          {g.parent.category}
                        </Badge>
                      </TableCell>

                      {/* Price range */}
                      <TableCell className="text-sm text-muted-foreground">
                        {groupPriceLabel(g)}
                      </TableCell>

                      {/* Margin — not meaningful at parent level */}
                      <TableCell>
                        <span className="text-muted-foreground text-xs">—</span>
                      </TableCell>

                      {/* Aggregated stock */}
                      <TableCell onClick={(e) => e.stopPropagation()}>
                        <span className="font-bold text-foreground">{stock}</span>
                        <span className="text-muted-foreground text-xs ml-1">uds</span>
                      </TableCell>

                      {/* Semaphore */}
                      <TableCell onClick={(e) => e.stopPropagation()}>
                        <StockSemaphore stock={stock} minStock={minStock} size="sm" />
                      </TableCell>

                      {/* Actions */}
                      <TableCell onClick={(e) => e.stopPropagation()}>
                        <div className="flex items-center justify-end gap-1">
                          <Button
                            variant="ghost"
                            size="sm"
                            className="h-7 px-2 text-xs text-primary hover:text-primary hover:bg-primary/10"
                            onClick={() => onAddVariant(g.parent)}
                          >
                            <Plus className="h-3 w-3 mr-0.5" />
                            Variante
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon"
                            className="h-7 w-7 text-muted-foreground hover:text-primary"
                            onClick={() => onEdit(g.parent)}
                          >
                            <Pencil className="h-3.5 w-3.5" />
                          </Button>
                          <DeleteDialog
                            id={g.parent.id}
                            label={g.parent.name}
                            childCount={g.children.length}
                            onConfirm={handleDelete}
                            isDeleting={deletingId === g.parent.id}
                          />
                        </div>
                      </TableCell>
                    </TableRow>

                    {/* ── Variant rows (visible when expanded) ── */}
                    {expanded &&
                      g.children.map((child, idx) => {
                        const isLast = idx === g.children.length - 1
                        return (
                          <TableRow
                            key={child.id}
                            className="border-border hover:bg-accent/30 bg-accent/10"
                          >
                            {/* Tree-line indent cell */}
                            <TableCell className="relative p-0">
                              <div
                                className={cn(
                                  "absolute left-1/2 top-0 w-px bg-border/60",
                                  isLast ? "h-1/2" : "h-full",
                                )}
                              />
                              <div className="absolute left-1/2 top-1/2 w-3 h-px bg-border/60" />
                            </TableCell>

                            {/* Variant name with tree symbol */}
                            <TableCell>
                              <div className="flex items-center gap-2 pl-4">
                                <span className="text-muted-foreground select-none text-sm">
                                  {isLast ? "└" : "├"}
                                </span>
                                <div className="flex flex-col gap-0.5">
                                  <span className="text-sm text-foreground">
                                    {child.name}
                                  </span>
                                  {child.barcode && (
                                    <code className="text-[10px] bg-muted px-1 rounded text-muted-foreground self-start">
                                      {child.barcode}
                                    </code>
                                  )}
                                </div>
                              </div>
                            </TableCell>

                            {/* Category — inherited, show muted */}
                            <TableCell>
                              <span className="text-xs text-muted-foreground/50">
                                {child.category}
                              </span>
                            </TableCell>

                            {/* Price */}
                            <TableCell>
                              <span className="text-sm font-medium text-emerald-400">
                                {formatMoney(child.price)}
                              </span>
                            </TableCell>

                            {/* Margin */}
                            <TableCell>
                              <span
                                className={cn(
                                  "text-xs font-medium",
                                  child.margin >= 50
                                    ? "text-emerald-400"
                                    : child.margin >= 30
                                      ? "text-yellow-400"
                                      : "text-red-400",
                                )}
                              >
                                {child.margin}%
                              </span>
                            </TableCell>

                            {/* Stock */}
                            <TableCell>
                              <span className="text-sm">{child.stock}</span>
                            </TableCell>

                            {/* Semaphore */}
                            <TableCell>
                              <StockSemaphore
                                stock={child.stock}
                                minStock={child.minStock}
                                size="sm"
                              />
                            </TableCell>

                            {/* Actions */}
                            <TableCell>
                              <div className="flex items-center justify-end gap-1">
                                <Button
                                  variant="ghost"
                                  size="icon"
                                  className="h-7 w-7 text-muted-foreground hover:text-primary"
                                  onClick={() => onEdit(child)}
                                >
                                  <Pencil className="h-3.5 w-3.5" />
                                </Button>
                                <DeleteDialog
                                  id={child.id}
                                  label={child.name}
                                  onConfirm={handleDelete}
                                  isDeleting={deletingId === child.id}
                                />
                              </div>
                            </TableCell>
                          </TableRow>
                        )
                      })}
                  </Fragment>
                )
              })}

              {/* Standalone products (no parent, no children) */}
              {filteredStandalones.map((p) => (
                <TableRow
                  key={p.id}
                  className="border-border hover:bg-accent/50"
                >
                  {/* Package icon */}
                  <TableCell>
                    <div className="flex items-center justify-center">
                      <Package className="h-4 w-4 text-muted-foreground/40" />
                    </div>
                  </TableCell>

                  {/* Name + barcode */}
                  <TableCell>
                    <div className="flex flex-col gap-0.5">
                      <span className="font-medium text-foreground">{p.name}</span>
                      {p.barcode && (
                        <code className="text-[10px] bg-muted px-1 rounded text-muted-foreground self-start">
                          {p.barcode}
                        </code>
                      )}
                    </div>
                  </TableCell>

                  {/* Category */}
                  <TableCell>
                    <Badge
                      variant="outline"
                      className="text-xs border-border text-muted-foreground"
                    >
                      {p.category}
                    </Badge>
                  </TableCell>

                  {/* Price */}
                  <TableCell>
                    <span className="font-medium text-emerald-400">
                      {formatMoney(p.price)}
                    </span>
                  </TableCell>

                  {/* Margin */}
                  <TableCell>
                    <span
                      className={cn(
                        "text-xs font-medium",
                        p.margin >= 50
                          ? "text-emerald-400"
                          : p.margin >= 30
                            ? "text-yellow-400"
                            : "text-red-400",
                      )}
                    >
                      {p.margin}%
                    </span>
                  </TableCell>

                  {/* Stock */}
                  <TableCell>
                    <span className="text-sm">{p.stock}</span>
                  </TableCell>

                  {/* Semaphore */}
                  <TableCell>
                    <StockSemaphore
                      stock={p.stock}
                      minStock={p.minStock}
                      size="sm"
                    />
                  </TableCell>

                  {/* Actions */}
                  <TableCell>
                    <div className="flex items-center justify-end gap-1">
                      <Button
                        variant="ghost"
                        size="sm"
                        className="h-7 px-2 text-xs text-muted-foreground hover:text-primary hover:bg-primary/10"
                        onClick={() => onAddVariant(p)}
                        title="Agregar variante a este producto"
                      >
                        <Plus className="h-3 w-3 mr-0.5" />
                        Variante
                      </Button>
                      <Button
                        variant="ghost"
                        size="icon"
                        className="h-7 w-7 text-muted-foreground hover:text-primary"
                        onClick={() => onEdit(p)}
                      >
                        <Pencil className="h-3.5 w-3.5" />
                      </Button>
                      <DeleteDialog
                        id={p.id}
                        label={p.name}
                        onConfirm={handleDelete}
                        isDeleting={deletingId === p.id}
                      />
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      </div>

      {/* Footer count */}
      <p className="text-xs text-muted-foreground">
        {search
          ? `${
              filteredGroups.length +
              filteredGroups.reduce((s, g) => s + g.children.length, 0) +
              filteredStandalones.length
            } resultado${
              filteredGroups.length + filteredStandalones.length !== 1 ? "s" : ""
            } de ${totalProducts} productos`
          : `${totalProducts} producto${totalProducts !== 1 ? "s" : ""} en catálogo`}
      </p>
    </div>
  )
}

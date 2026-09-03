"use client"

import { Fragment, useState, useMemo, useCallback, useRef, type ReactNode } from "react"
import {
  ChevronRight, ChevronDown, Plus, Search, Download, Upload,
  Pencil, Trash2, Package, GitBranch, Wrench, Sparkles, Shapes,
} from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Badge } from "@/components/ui/badge"
import { Checkbox } from "@/components/ui/checkbox"
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from "@/components/ui/table"
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog"
import { StockSemaphore } from "@/components/stock/stock-semaphore"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { formatMoney } from "@/lib/format"
import { formatStock } from "@/lib/format-unit"
import { resolveUnit } from "@/lib/unit-utils"
import { exportToCSV } from "@/lib/excel"
import { humanizeOperationError } from "@/lib/operation-errors"
import type { Product } from "@/lib/types"
import { toast } from "sonner"
import { cn } from "@/lib/utils"
import { ProductImportDialog } from "@/components/products/product-import-dialog"
import { ProductCategorySelect } from "@/components/product-categories/ProductCategorySelect"
import { useProductCategories } from "@/hooks/data/use-product-categories"
import type { BulkCategoryResult } from "@/lib/product-bulk-category"

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
  /** Called after a successful CSV import to trigger data refresh. */
  onImportComplete?: () => void
  /**
   * When provided, a "Sugerir precio IA" button is shown for each standalone
   * product and variant (not for parent-only catalogue entries). Controlled
   * by the parent — the parent is responsible for plan gating.
   */
  onSuggestPrice?: (product: Product) => void
  /**
   * productos-categorias-sku (D14): recategorización en lote. Recibe los ids
   * seleccionados (padres y simples) y la categoría destino; el padre propaga
   * a sus variantes en el SERVIDOR. Sin este prop la selección se ofrece pero
   * la acción queda deshabilitada.
   */
  onBulkRecategorize?: (productIds: string[], categoryId: string) => Promise<BulkCategoryResult>
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
  onImportComplete,
  onSuggestPrice,
  onBulkRecategorize,
}: ProductCatalogProps) {
  const [search, setSearch] = useState("")
  const [expandedIds, setExpandedIds] = useState<Set<string>>(new Set())
  const [deletingId, setDeletingId] = useState<string | null>(null)
  const [importDialogOpen, setImportDialogOpen] = useState(false)

  // ── productos-categorias-sku (D14): selección múltiple + lote ─────────────
  // Mismo idioma Set<string> que expandedIds (y ReconciliationBoard).
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())
  const [bulkCategoryId, setBulkCategoryId] = useState<string | null>(null)
  const [bulkConfirmOpen, setBulkConfirmOpen] = useState(false)
  const [bulkApplying, setBulkApplying] = useState(false)
  const { productCategories } = useProductCategories(true)
  const bulkTargetName = productCategories.find((c) => c.id === bulkCategoryId)?.name ?? null

  // ── Unit-of-measure resolution ─────────────────────────────────────────────
  // unitsById comes pre-built from the hook — no local useMemo needed
  const { unitsById } = useUnitsOfMeasure()

  /** Stock cell content for a single tracked product. */
  function stockLabel(p: Product): ReactNode {
    if (p.stockControlType === "untracked") {
      return (
        <span className="inline-flex items-center gap-1 text-xs text-muted-foreground">
          <Wrench className="h-3 w-3" />
          Servicio
        </span>
      )
    }
    const sym = resolveUnit(p.baseUnitId, unitsById)?.symbol
    return (
      <span className="font-bold text-foreground tabular-nums">
        {formatStock(p.stock, sym)}
      </span>
    )
  }

  /** Aggregated stock label for a variant group. */
  function groupStockLabel(g: ProductGroup): ReactNode {
    const total = groupStock(g)
    // Use the symbol from the first child that has a unit assigned
    const firstWithUnit = g.children.find((c) => c.baseUnitId)
    const sym = resolveUnit(firstWithUnit?.baseUnitId, unitsById)?.symbol
    return (
      <span className="font-bold text-foreground tabular-nums">
        {formatStock(total, sym)}
      </span>
    )
  }

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

  // ── Filter by search ───────────────────────────────────────────────────────
  // Groups are NOT auto-expanded on match: parents stay collapsed until the user
  // toggles them (same as the no-search view). A child-only match still surfaces
  // its parent — collapsed — with the matching variants revealed on expand.
  const { filteredGroups, filteredStandalones } = useMemo(() => {
    if (!search.trim()) {
      return { filteredGroups: groups, filteredStandalones: standalones }
    }

    const q = search.toLowerCase()

    const filteredGroups = groups
      .map((g) => {
        // productos-categorias-sku (13.3): el SKU entra a los predicados.
        const parentHit =
          g.parent.name.toLowerCase().includes(q) ||
          (g.parent.category ?? "").toLowerCase().includes(q) ||
          (g.parent.barcode ?? "").toLowerCase().includes(q) ||
          (g.parent.sku ?? "").toLowerCase().includes(q)

        const matchingChildren = g.children.filter(
          (c) =>
            c.name.toLowerCase().includes(q) ||
            (c.barcode ?? "").toLowerCase().includes(q) ||
            (c.sku ?? "").toLowerCase().includes(q),
        )

        if (!parentHit && matchingChildren.length === 0) return null

        return { parent: g.parent, children: parentHit ? g.children : matchingChildren }
      })
      .filter(Boolean) as ProductGroup[]

    const filteredStandalones = standalones.filter(
      (p) =>
        p.name.toLowerCase().includes(q) ||
        (p.category ?? "").toLowerCase().includes(q) ||
        (p.barcode ?? "").toLowerCase().includes(q) ||
        (p.sku ?? "").toLowerCase().includes(q),
    )

    return { filteredGroups, filteredStandalones }
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
    return expandedIds.has(parentId)
  }

  // ── Selección (D14) ───────────────────────────────────────────────────────
  // Sólo padres y productos simples son seleccionables: la categoría de una
  // variante es derivada (D11) y el servidor expande el padre al grupo.
  const visibleRootIds = useMemo(
    () => [...filteredGroups.map((g) => g.parent.id), ...filteredStandalones.map((p) => p.id)],
    [filteredGroups, filteredStandalones],
  )
  const allVisibleSelected = visibleRootIds.length > 0 && visibleRootIds.every((id) => selectedIds.has(id))
  const someVisibleSelected = visibleRootIds.some((id) => selectedIds.has(id))

  function toggleSelect(id: string) {
    setSelectedIds((prev) => {
      const next = new Set(prev)
      next.has(id) ? next.delete(id) : next.add(id)
      return next
    })
  }

  function toggleSelectAll() {
    setSelectedIds(allVisibleSelected ? new Set() : new Set(visibleRootIds))
  }

  function clearSelection() {
    setSelectedIds(new Set())
    setBulkCategoryId(null)
  }

  // La selección no sobrevive a un cambio de búsqueda: nadie recategoriza a
  // ciegas un conjunto que ya no está viendo.
  function handleSearchChange(value: string) {
    setSearch(value)
    setSelectedIds(new Set())
  }

  async function handleBulkApply() {
    if (!onBulkRecategorize || !bulkCategoryId || selectedIds.size === 0) return
    const ids = [...selectedIds]
    setBulkApplying(true)
    try {
      const res = await onBulkRecategorize(ids, bulkCategoryId)
      // Resultado REAL (14.8): 0 actualizados no es error; menos de lo
      // solicitado se dice, no se afirma un éxito total.
      if (res.updated === 0) {
        toast.info("Los productos seleccionados ya tenían esa categoría — no hubo cambios.")
      } else if (res.updated < res.requested) {
        toast.warning(
          `Se recategorizaron ${res.updated} de ${res.requested} productos — algunos no se pudieron actualizar.`,
        )
      } else {
        toast.success(
          `${res.updated} producto${res.updated !== 1 ? "s" : ""} recategorizado${res.updated !== 1 ? "s" : ""}${bulkTargetName ? ` a "${bulkTargetName}"` : ""}.`,
        )
      }
      clearSelection()
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Error al recategorizar"
      toast.error(humanizeOperationError(msg).message)
    } finally {
      setBulkApplying(false)
      setBulkConfirmOpen(false)
    }
  }

  // ── Delete with loading guard ──────────────────────────────────────────────
  const handleDelete = useCallback(
    async (id: string) => {
      setDeletingId(id)
      try {
        await onDelete(id)
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : "Error al eliminar"
        // G10 (H21a): el detail crudo del backend (RN-B4 + 4 decimales) se
        // traduce en el mapa canónico; un error no reconocido pasa intacto.
        toast.error(humanizeOperationError(msg).message)
      } finally {
        setDeletingId(null)
      }
    },
    [onDelete],
  )

  // ── Import from CSV — handled by ProductImportDialog ─────────────────────

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
            onChange={(e) => handleSearchChange(e.target.value)}
            className="pl-9 bg-background border-border text-foreground"
          />
        </div>

        {/* qa-integral-modulos G2 (H2/2.4): flex-wrap — la barra sin wrap
            empujaba el ancho de la página en móvil. */}
        <div className="flex flex-wrap items-center gap-2">
          <Button
            variant="outline"
            size="sm"
            className="border-border text-foreground"
            onClick={() => setImportDialogOpen(true)}
          >
            <Upload className="h-4 w-4 mr-1" />
            Importar CSV
          </Button>

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

      {/* ── productos-categorias-sku (D14): barra de acción en lote ─────── */}
      {selectedIds.size > 0 && (
        <section
          role="region"
          aria-label="Acciones en lote"
          aria-live="polite"
          className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between rounded-lg border border-primary/30 bg-primary/5 px-3 py-2"
        >
          <div className="flex items-center gap-2 text-sm text-foreground">
            <Shapes className="h-4 w-4 text-primary shrink-0" />
            <span className="font-medium">
              {selectedIds.size} seleccionado{selectedIds.size !== 1 ? "s" : ""}
            </span>
            <Button variant="ghost" size="sm" className="h-7 px-2 text-xs text-muted-foreground" onClick={clearSelection}>
              Limpiar
            </Button>
          </div>
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
            <div className="w-full sm:w-56">
              <ProductCategorySelect
                value={bulkCategoryId}
                onChange={setBulkCategoryId}
                showLabel={false}
                label="Categoría destino"
                placeholder="Categoría destino"
              />
            </div>
            <Button
              size="sm"
              onClick={() => setBulkConfirmOpen(true)}
              disabled={!bulkCategoryId || !onBulkRecategorize || bulkApplying}
            >
              Cambiar categoría
            </Button>
          </div>
        </section>
      )}

      {/* ── Mobile card list (sm:hidden) ─────────────────────────────────── */}
      <div className="sm:hidden flex flex-col gap-2">
        {visibleRootIds.length > 0 && (
          <label className="flex items-center gap-2 px-1 text-xs text-muted-foreground">
            <Checkbox
              aria-label="Seleccionar todos"
              checked={allVisibleSelected ? true : someVisibleSelected ? "indeterminate" : false}
              onCheckedChange={toggleSelectAll}
            />
            Seleccionar todos
          </label>
        )}
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
                          <Checkbox
                            aria-label={`Seleccionar ${g.parent.name}`}
                            checked={selectedIds.has(g.parent.id)}
                            onCheckedChange={() => toggleSelect(g.parent.id)}
                          />
                          <button
                            onClick={() => toggleExpand(g.parent.id)}
                            aria-label={expanded ? "Colapsar variantes" : "Expandir variantes"}
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
                        <span className="text-xs text-muted-foreground">{groupStockLabel(g)}</span>
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
                          {child.sku && (
                            <code className="text-[10px] bg-muted px-1 rounded text-muted-foreground ml-1">SKU {child.sku}</code>
                          )}
                        </div>
                        {child.stockControlType !== "untracked" && (
                          <StockSemaphore stock={child.stock} minStock={child.minStock} size="sm" />
                        )}
                      </div>
                      <div className="flex items-center justify-between text-xs">
                        <span className="text-success font-medium">{formatMoney(child.price)}</span>
                        <span className={cn(
                          "font-medium",
                          child.margin >= 50 ? "text-success" : child.margin >= 30 ? "text-warning" : "text-destructive"
                        )}>
                          {child.margin}% margen
                        </span>
                        <span className="text-muted-foreground text-xs">{stockLabel(child)}</span>
                      </div>
                      <div className="flex items-center justify-end gap-1 pt-1 border-t border-border">
                        {onSuggestPrice && (
                          <Button
                            variant="ghost"
                            size="sm"
                            className="h-7 px-2 text-xs text-primary hover:text-primary hover:bg-primary/10"
                            onClick={() => onSuggestPrice(child)}
                            title="Sugerir precio IA"
                          >
                            <Sparkles className="h-3 w-3 mr-0.5" />
                            Precio IA
                          </Button>
                        )}
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
                  <div className="min-w-0 flex items-start gap-1.5">
                    <Checkbox
                      aria-label={`Seleccionar ${p.name}`}
                      checked={selectedIds.has(p.id)}
                      onCheckedChange={() => toggleSelect(p.id)}
                      className="mt-0.5"
                    />
                    <div className="min-w-0">
                    <span className="font-medium text-sm text-foreground truncate block">{p.name}</span>
                    {p.barcode && (
                      <code className="text-[10px] bg-muted px-1 rounded text-muted-foreground">{p.barcode}</code>
                    )}
                    {p.sku && (
                      <code className="text-[10px] bg-muted px-1 rounded text-muted-foreground ml-1">SKU {p.sku}</code>
                    )}
                    </div>
                  </div>
                  {p.stockControlType !== "untracked" && (
                    <StockSemaphore stock={p.stock} minStock={p.minStock} size="sm" />
                  )}
                </div>
                <div className="flex items-center justify-between gap-2">
                  <Badge variant="outline" className="text-xs border-border text-muted-foreground">
                    {p.category}
                  </Badge>
                  <div className="flex items-center gap-2 text-xs">
                    <span className="text-success font-medium">{formatMoney(p.price)}</span>
                    <span className={cn(
                      "font-medium",
                      p.margin >= 50 ? "text-success" : p.margin >= 30 ? "text-warning" : "text-destructive"
                    )}>
                      {p.margin}%
                    </span>
                    <span className="text-muted-foreground text-xs">{stockLabel(p)}</span>
                  </div>
                </div>
                <div className="flex items-center justify-end gap-1 pt-1 border-t border-border">
                  {onSuggestPrice && (
                    <Button
                      variant="ghost"
                      size="sm"
                      className="h-7 px-2 text-xs text-primary hover:text-primary hover:bg-primary/10"
                      onClick={() => onSuggestPrice(p)}
                      title="Sugerir precio IA"
                    >
                      <Sparkles className="h-3 w-3 mr-0.5" />
                      Precio IA
                    </Button>
                  )}
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
                <TableHead className="w-14">
                  <Checkbox
                    aria-label="Seleccionar todos"
                    checked={allVisibleSelected ? true : someVisibleSelected ? "indeterminate" : false}
                    onCheckedChange={toggleSelectAll}
                    disabled={visibleRootIds.length === 0}
                  />
                </TableHead>
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
                      {/* Selección (D14) + expand toggle — stopPropagation para no
                          duplicar el toggle con el onClick de la fila. */}
                      <TableCell onClick={(e) => e.stopPropagation()}>
                        <div className="flex items-center gap-1">
                        <Checkbox
                          aria-label={`Seleccionar ${g.parent.name}`}
                          checked={selectedIds.has(g.parent.id)}
                          onCheckedChange={() => toggleSelect(g.parent.id)}
                        />
                        <Button
                          variant="ghost"
                          size="icon"
                          className="h-6 w-6 text-muted-foreground hover:text-foreground"
                          aria-label={expanded ? "Colapsar variantes" : "Expandir variantes"}
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
                        </div>
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
                        {groupStockLabel(g)}
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
                                  {child.sku && (
                                    <code className="text-[10px] bg-muted px-1 rounded text-muted-foreground self-start">
                                      SKU {child.sku}
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
                              <span className="text-sm font-medium text-success">
                                {formatMoney(child.price)}
                              </span>
                            </TableCell>

                            {/* Margin */}
                            <TableCell>
                              <span
                                className={cn(
                                  "text-xs font-medium",
                                  child.margin >= 50
                                    ? "text-success"
                                    : child.margin >= 30
                                      ? "text-warning"
                                      : "text-destructive",
                                )}
                              >
                                {child.margin}%
                              </span>
                            </TableCell>

                            {/* Stock */}
                            <TableCell>
                              {stockLabel(child)}
                            </TableCell>

                            {/* Semaphore */}
                            <TableCell>
                              {child.stockControlType !== "untracked" && (
                                <StockSemaphore
                                  stock={child.stock}
                                  minStock={child.minStock}
                                  size="sm"
                                />
                              )}
                            </TableCell>

                            {/* Actions */}
                            <TableCell>
                              <div className="flex items-center justify-end gap-1">
                                {onSuggestPrice && (
                                  <Button
                                    variant="ghost"
                                    size="sm"
                                    className="h-7 px-2 text-xs text-primary hover:text-primary hover:bg-primary/10"
                                    onClick={() => onSuggestPrice(child)}
                                    title="Sugerir precio IA"
                                  >
                                    <Sparkles className="h-3 w-3 mr-0.5" />
                                    Precio IA
                                  </Button>
                                )}
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
                  {/* Selección (D14) + Package icon */}
                  <TableCell>
                    <div className="flex items-center gap-1">
                      <Checkbox
                        aria-label={`Seleccionar ${p.name}`}
                        checked={selectedIds.has(p.id)}
                        onCheckedChange={() => toggleSelect(p.id)}
                      />
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
                      {p.sku && (
                        <code className="text-[10px] bg-muted px-1 rounded text-muted-foreground self-start">
                          SKU {p.sku}
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
                    <span className="font-medium text-success">
                      {formatMoney(p.price)}
                    </span>
                  </TableCell>

                  {/* Margin */}
                  <TableCell>
                    <span
                      className={cn(
                        "text-xs font-medium",
                        p.margin >= 50
                          ? "text-success"
                          : p.margin >= 30
                            ? "text-warning"
                            : "text-destructive",
                      )}
                    >
                      {p.margin}%
                    </span>
                  </TableCell>

                  {/* Stock */}
                  <TableCell>
                    {stockLabel(p)}
                  </TableCell>

                  {/* Semaphore */}
                  <TableCell>
                    {p.stockControlType !== "untracked" && (
                      <StockSemaphore
                        stock={p.stock}
                        minStock={p.minStock}
                        size="sm"
                      />
                    )}
                  </TableCell>

                  {/* Actions */}
                  <TableCell>
                    <div className="flex items-center justify-end gap-1">
                      {onSuggestPrice && (
                        <Button
                          variant="ghost"
                          size="sm"
                          className="h-7 px-2 text-xs text-primary hover:text-primary hover:bg-primary/10"
                          onClick={() => onSuggestPrice(p)}
                          title="Sugerir precio IA"
                        >
                          <Sparkles className="h-3 w-3 mr-0.5" />
                          Precio IA
                        </Button>
                      )}
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

      {/* ── Confirmación del lote (D14): declara alcance y destino antes de aplicar */}
      <AlertDialog open={bulkConfirmOpen} onOpenChange={(open) => { if (!bulkApplying) setBulkConfirmOpen(open) }}>
        <AlertDialogContent className="bg-card border-border">
          <AlertDialogHeader>
            <AlertDialogTitle className="text-card-foreground">Cambiar categoría</AlertDialogTitle>
            <AlertDialogDescription>
              {`Vas a asignar la categoría "${bulkTargetName ?? ""}" a ${selectedIds.size} producto${selectedIds.size !== 1 ? "s" : ""}. Las variantes de un producto padre heredan su categoría. Se puede volver a cambiar con esta misma herramienta.`}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel className="border-border text-foreground" disabled={bulkApplying}>
              Cancelar
            </AlertDialogCancel>
            <AlertDialogAction
              onClick={(e) => { e.preventDefault(); void handleBulkApply() }}
              disabled={bulkApplying}
            >
              {bulkApplying ? "Aplicando…" : "Recategorizar"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      {/* Import dialog */}
      <ProductImportDialog
        open={importDialogOpen}
        onOpenChange={setImportDialogOpen}
        onComplete={() => {
          setImportDialogOpen(false)
          onImportComplete?.()
        }}
      />
    </div>
  )
}

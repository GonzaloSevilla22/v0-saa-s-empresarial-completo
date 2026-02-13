"use client"

import { useState, useMemo, useRef } from "react"
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from "@/components/ui/table"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { ArrowUpDown, Search, Plus, Trash2, Download, Upload, CalendarDays, X } from "lucide-react"
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog"
import {
  Popover, PopoverContent, PopoverTrigger,
} from "@/components/ui/popover"
import { exportToCSV, parseCSV, readFileAsText } from "@/lib/excel"
import { toast } from "sonner"

export interface Column<T> {
  key: string
  header: string
  cell: (row: T) => React.ReactNode
  sortable?: boolean
  sortValue?: (row: T) => string | number
}

export interface ExportColumn {
  key: string
  header: string
}

export interface ImportColumnMap {
  csvHeader: string
  key: string
}

interface DataTableProps<T> {
  data: T[]
  columns: Column<T>[]
  searchPlaceholder?: string
  searchKey?: (row: T) => string
  onAdd?: () => void
  addLabel?: string
  onDelete?: (id: string) => void
  getId: (row: T) => string
  // Date filter
  dateKey?: (row: T) => string
  // Export/Import
  exportColumns?: ExportColumn[]
  exportFilename?: string
  importColumnMap?: ImportColumnMap[]
  onImport?: (rows: Record<string, string>[]) => void
}

export function DataTable<T>({
  data, columns, searchPlaceholder = "Buscar...", searchKey,
  onAdd, addLabel = "Agregar", onDelete, getId,
  dateKey, exportColumns, exportFilename, importColumnMap, onImport,
}: DataTableProps<T>) {
  const [search, setSearch] = useState("")
  const [sortKey, setSortKey] = useState<string | null>(null)
  const [sortDir, setSortDir] = useState<"asc" | "desc">("desc")
  const [page, setPage] = useState(0)
  const [dateFrom, setDateFrom] = useState("")
  const [dateTo, setDateTo] = useState("")
  const fileInputRef = useRef<HTMLInputElement>(null)
  const pageSize = 10

  const hasDateFilter = !!dateKey
  const hasExport = !!exportColumns && !!exportFilename
  const hasImport = !!importColumnMap && !!onImport

  // Filter by search
  const searchFiltered = useMemo(() => {
    if (!search || !searchKey) return data
    const lower = search.toLowerCase()
    return data.filter((row) => searchKey(row).toLowerCase().includes(lower))
  }, [data, search, searchKey])

  // Filter by date range
  const dateFiltered = useMemo(() => {
    if (!dateKey || (!dateFrom && !dateTo)) return searchFiltered
    return searchFiltered.filter((row) => {
      const d = dateKey(row)
      if (dateFrom && d < dateFrom) return false
      if (dateTo && d > dateTo) return false
      return true
    })
  }, [searchFiltered, dateKey, dateFrom, dateTo])

  const sorted = useMemo(() => {
    if (!sortKey) return dateFiltered
    const col = columns.find((c) => c.key === sortKey)
    if (!col?.sortValue) return dateFiltered
    return [...dateFiltered].sort((a, b) => {
      const va = col.sortValue!(a)
      const vb = col.sortValue!(b)
      if (va < vb) return sortDir === "asc" ? -1 : 1
      if (va > vb) return sortDir === "asc" ? 1 : -1
      return 0
    })
  }, [dateFiltered, sortKey, sortDir, columns])

  const paginated = sorted.slice(page * pageSize, (page + 1) * pageSize)
  const totalPages = Math.ceil(sorted.length / pageSize)

  function handleSort(key: string) {
    if (sortKey === key) {
      setSortDir((d) => (d === "asc" ? "desc" : "asc"))
    } else {
      setSortKey(key)
      setSortDir("desc")
    }
  }

  function handleExport() {
    if (!exportColumns || !exportFilename) return
    const exportData = sorted.map((row) => {
      const obj: Record<string, unknown> = {}
      for (const col of exportColumns) {
        obj[col.key] = (row as Record<string, unknown>)[col.key]
      }
      return obj
    })
    exportToCSV(exportData, exportColumns, exportFilename)
    toast.success(`Exportado ${exportData.length} registros`)
  }

  async function handleImport(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file || !importColumnMap || !onImport) return
    try {
      const text = await readFileAsText(file)
      const rows = parseCSV(text, importColumnMap)
      if (rows.length === 0) {
        toast.error("No se encontraron datos en el archivo")
        return
      }
      onImport(rows)
      toast.success(`Importados ${rows.length} registros`)
    } catch {
      toast.error("Error al leer el archivo")
    }
    if (fileInputRef.current) fileInputRef.current.value = ""
  }

  const isDateFilterActive = dateFrom || dateTo

  return (
    <div className="flex flex-col gap-4">
      {/* Top bar */}
      <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:gap-3">
          <div className="relative w-full sm:w-64">
            <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              placeholder={searchPlaceholder}
              value={search}
              onChange={(e) => { setSearch(e.target.value); setPage(0) }}
              className="pl-9 bg-background border-border text-foreground"
            />
          </div>

          {hasDateFilter && (
            <Popover>
              <PopoverTrigger asChild>
                <Button
                  variant="outline"
                  size="sm"
                  className={`shrink-0 border-border text-foreground ${isDateFilterActive ? "border-primary text-primary" : ""}`}
                >
                  <CalendarDays className="h-4 w-4 mr-1" />
                  Filtrar fechas
                  {isDateFilterActive && (
                    <span className="ml-1.5 flex h-4 w-4 items-center justify-center rounded-full bg-primary text-[10px] text-primary-foreground">
                      1
                    </span>
                  )}
                </Button>
              </PopoverTrigger>
              <PopoverContent className="w-72 bg-popover border-border" align="start">
                <div className="flex flex-col gap-3">
                  <p className="text-sm font-medium text-foreground">Rango de fechas</p>
                  <div className="flex flex-col gap-2">
                    <Label className="text-xs text-muted-foreground">Desde</Label>
                    <Input
                      type="date"
                      value={dateFrom}
                      onChange={(e) => { setDateFrom(e.target.value); setPage(0) }}
                      className="bg-background border-border text-foreground"
                    />
                  </div>
                  <div className="flex flex-col gap-2">
                    <Label className="text-xs text-muted-foreground">Hasta</Label>
                    <Input
                      type="date"
                      value={dateTo}
                      onChange={(e) => { setDateTo(e.target.value); setPage(0) }}
                      className="bg-background border-border text-foreground"
                    />
                  </div>
                  {isDateFilterActive && (
                    <Button
                      variant="ghost"
                      size="sm"
                      className="text-muted-foreground"
                      onClick={() => { setDateFrom(""); setDateTo(""); setPage(0) }}
                    >
                      <X className="h-3 w-3 mr-1" />
                      Limpiar filtro
                    </Button>
                  )}
                </div>
              </PopoverContent>
            </Popover>
          )}
        </div>

        <div className="flex items-center gap-2 flex-wrap">
          {hasImport && (
            <>
              <input
                type="file"
                ref={fileInputRef}
                accept=".csv,.txt"
                className="hidden"
                onChange={handleImport}
              />
              <Button
                variant="outline"
                size="sm"
                className="border-border text-foreground"
                onClick={() => fileInputRef.current?.click()}
              >
                <Upload className="h-4 w-4 mr-1" />
                Importar
              </Button>
            </>
          )}
          {hasExport && (
            <Button
              variant="outline"
              size="sm"
              className="border-border text-foreground"
              onClick={handleExport}
            >
              <Download className="h-4 w-4 mr-1" />
              Exportar
            </Button>
          )}
          {onAdd && (
            <Button onClick={onAdd} size="sm" className="shrink-0">
              <Plus className="h-4 w-4 mr-1" />
              {addLabel}
            </Button>
          )}
        </div>
      </div>

      {/* Table */}
      <div className="rounded-lg border border-border overflow-hidden">
        <div className="overflow-x-auto">
          <Table>
            <TableHeader>
              <TableRow className="border-border hover:bg-transparent">
                {columns.map((col) => (
                  <TableHead key={col.key} className="text-muted-foreground text-xs font-medium uppercase tracking-wider">
                    {col.sortable ? (
                      <button
                        onClick={() => handleSort(col.key)}
                        className="flex items-center gap-1 hover:text-foreground transition-colors"
                      >
                        {col.header}
                        <ArrowUpDown className="h-3 w-3" />
                      </button>
                    ) : (
                      col.header
                    )}
                  </TableHead>
                ))}
                {onDelete && <TableHead className="w-10" />}
              </TableRow>
            </TableHeader>
            <TableBody>
              {paginated.length === 0 ? (
                <TableRow>
                  <TableCell
                    colSpan={columns.length + (onDelete ? 1 : 0)}
                    className="h-32 text-center text-muted-foreground"
                  >
                    No se encontraron resultados
                  </TableCell>
                </TableRow>
              ) : (
                paginated.map((row) => (
                  <TableRow key={getId(row)} className="border-border hover:bg-accent/50">
                    {columns.map((col) => (
                      <TableCell key={col.key} className="text-sm text-card-foreground">
                        {col.cell(row)}
                      </TableCell>
                    ))}
                    {onDelete && (
                      <TableCell>
                        <AlertDialog>
                          <AlertDialogTrigger asChild>
                            <Button variant="ghost" size="icon" className="h-7 w-7 text-muted-foreground hover:text-destructive">
                              <Trash2 className="h-3.5 w-3.5" />
                            </Button>
                          </AlertDialogTrigger>
                          <AlertDialogContent className="bg-card border-border">
                            <AlertDialogHeader>
                              <AlertDialogTitle className="text-card-foreground">Confirmar eliminacion</AlertDialogTitle>
                              <AlertDialogDescription>
                                Esta accion no se puede deshacer. El registro sera eliminado permanentemente.
                              </AlertDialogDescription>
                            </AlertDialogHeader>
                            <AlertDialogFooter>
                              <AlertDialogCancel className="border-border text-foreground">Cancelar</AlertDialogCancel>
                              <AlertDialogAction
                                onClick={() => onDelete(getId(row))}
                                className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
                              >
                                Eliminar
                              </AlertDialogAction>
                            </AlertDialogFooter>
                          </AlertDialogContent>
                        </AlertDialog>
                      </TableCell>
                    )}
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </div>
      </div>

      {/* Pagination */}
      {totalPages > 1 && (
        <div className="flex items-center justify-between text-sm text-muted-foreground">
          <span>{sorted.length} registro(s)</span>
          <div className="flex items-center gap-2">
            <Button
              variant="outline"
              size="sm"
              disabled={page === 0}
              onClick={() => setPage(page - 1)}
              className="border-border text-foreground"
            >
              Anterior
            </Button>
            <span className="text-foreground">
              {page + 1} / {totalPages}
            </span>
            <Button
              variant="outline"
              size="sm"
              disabled={page >= totalPages - 1}
              onClick={() => setPage(page + 1)}
              className="border-border text-foreground"
            >
              Siguiente
            </Button>
          </div>
        </div>
      )}
    </div>
  )
}

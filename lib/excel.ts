/**
 * Exportar datos a CSV (compatible con Excel)
 */
export function exportToCSV<T extends Record<string, unknown>>(
  data: T[],
  columns: { key: string; header: string }[],
  filename: string
) {
  const BOM = "\uFEFF"
  const header = columns.map((c) => `"${c.header}"`).join(";")
  const rows = data.map((row) =>
    columns
      .map((c) => {
        const val = row[c.key]
        if (val === null || val === undefined) return ""
        const str = String(val).replace(/"/g, '""')
        return `"${str}"`
      })
      .join(";")
  )
  const csv = BOM + [header, ...rows].join("\n")
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8;" })
  const url = URL.createObjectURL(blob)
  const link = document.createElement("a")
  link.href = url
  link.download = `${filename}.csv`
  link.click()
  URL.revokeObjectURL(url)
}

/**
 * Importar datos desde CSV
 * Retorna un array de objetos con las claves mapeadas
 */
export function parseCSV(
  text: string,
  columnMap: { csvHeader: string; key: string }[]
): Record<string, string>[] {
  const lines = text.split(/\r?\n/).filter((l) => l.trim())
  if (lines.length < 2) return []

  // Detect separator
  const sep = lines[0].includes(";") ? ";" : ","

  const headers = lines[0].split(sep).map((h) => h.replace(/^"|"$/g, "").trim())

  const results: Record<string, string>[] = []

  for (let i = 1; i < lines.length; i++) {
    const values = lines[i].split(sep).map((v) => v.replace(/^"|"$/g, "").trim())
    const row: Record<string, string> = {}
    for (const cm of columnMap) {
      const idx = headers.findIndex(
        (h) => h.toLowerCase() === cm.csvHeader.toLowerCase()
      )
      if (idx >= 0 && values[idx] !== undefined) {
        row[cm.key] = values[idx]
      }
    }
    if (Object.keys(row).length > 0) {
      results.push(row)
    }
  }
  return results
}

/**
 * Lee un archivo como texto
 */
export function readFileAsText(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(reader.result as string)
    reader.onerror = reject
    reader.readAsText(file)
  })
}

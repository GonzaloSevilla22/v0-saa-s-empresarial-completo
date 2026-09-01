import { useState } from "react"
import { Input } from "@/components/ui/input"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { Plus, X } from "lucide-react"

interface CoverageAreaEditorProps {
  areas: string[]
  onChange: (areas: string[]) => void
}

/**
 * Editor de zonas de cobertura (`coverage_areas`, lista plana de strings —
 * design.md D3) desde `/admin/seguros`: agregar (Enter o botón) y quitar
 * cada zona como chip.
 */
export function CoverageAreaEditor({ areas, onChange }: CoverageAreaEditorProps) {
  const [draft, setDraft] = useState("")

  function addArea() {
    const value = draft.trim()
    if (!value || areas.includes(value)) {
      setDraft("")
      return
    }
    onChange([...areas, value])
    setDraft("")
  }

  function removeArea(area: string) {
    onChange(areas.filter((a) => a !== area))
  }

  return (
    <div className="flex flex-col gap-2">
      <div className="flex gap-2">
        <Input
          aria-label="Agregar zona de cobertura"
          placeholder="Ej: Mendoza"
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault()
              addArea()
            }
          }}
          className="bg-slate-800 border-slate-700 text-slate-100"
        />
        <Button
          type="button"
          variant="outline"
          size="sm"
          onClick={addArea}
          className="shrink-0 gap-1 border-slate-700 bg-slate-800/50 text-slate-300"
        >
          <Plus className="h-3.5 w-3.5" />
          Agregar zona
        </Button>
      </div>
      {areas.length > 0 ? (
        <div className="flex flex-wrap gap-2">
          {areas.map((area) => (
            <Badge key={area} variant="secondary" className="gap-1 pr-1">
              {area}
              <button
                type="button"
                aria-label={`Eliminar zona ${area}`}
                onClick={() => removeArea(area)}
                className="ml-1 rounded-full hover:bg-black/10"
              >
                <X className="h-3 w-3" />
              </button>
            </Badge>
          ))}
        </div>
      ) : null}
    </div>
  )
}

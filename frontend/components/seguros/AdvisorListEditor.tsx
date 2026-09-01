import { Input } from "@/components/ui/input"
import { Textarea } from "@/components/ui/textarea"
import { Button } from "@/components/ui/button"
import { Plus, Trash2, ArrowUp, ArrowDown } from "lucide-react"

export interface AdvisorListEditorItem {
  title: string
  text: string
}

interface AdvisorListEditorProps {
  /** Sustantivo singular en minúscula: "línea de servicio", "pilar". Se usa en los aria-label. */
  label: string
  textFieldLabel: string
  titlePlaceholder?: string
  textPlaceholder?: string
  items: AdvisorListEditorItem[]
  onChange: (items: AdvisorListEditorItem[]) => void
}

/**
 * Editor de una lista ordenada de pares título/texto (líneas de servicio,
 * pilares — design.md D3) desde `/admin/seguros`: agregar, borrar y
 * reordenar (subir/bajar), persistiendo el orden en el array que se envía
 * al guardar (task 7.3/7.6). Reutilizable para ambas listas del perfil de
 * asesor — sólo cambian las etiquetas.
 */
export function AdvisorListEditor({
  label,
  textFieldLabel,
  titlePlaceholder,
  textPlaceholder,
  items,
  onChange,
}: AdvisorListEditorProps) {
  function updateItem(index: number, patch: Partial<AdvisorListEditorItem>) {
    onChange(items.map((item, i) => (i === index ? { ...item, ...patch } : item)))
  }

  function removeItem(index: number) {
    onChange(items.filter((_, i) => i !== index))
  }

  function moveItem(index: number, direction: -1 | 1) {
    const target = index + direction
    if (target < 0 || target >= items.length) return
    const next = [...items]
    const [moved] = next.splice(index, 1)
    next.splice(target, 0, moved!)
    onChange(next)
  }

  function addItem() {
    onChange([...items, { title: "", text: "" }])
  }

  return (
    <div className="flex flex-col gap-3">
      {items.map((item, index) => (
        <div key={index} className="flex flex-col gap-2 rounded-md border border-slate-700 bg-slate-800/40 p-3">
          <div className="flex items-center gap-2">
            <Input
              aria-label={`Título de ${label} ${index + 1}`}
              placeholder={titlePlaceholder}
              value={item.title}
              onChange={(e) => updateItem(index, { title: e.target.value })}
              className="bg-slate-800 border-slate-700 text-slate-100"
            />
            <Button
              type="button"
              variant="outline"
              size="icon"
              aria-label={`Subir ${label} ${index + 1}`}
              onClick={() => moveItem(index, -1)}
              disabled={index === 0}
              className="h-9 w-9 shrink-0 border-slate-700 bg-slate-800/50 text-slate-300"
            >
              <ArrowUp className="h-3.5 w-3.5" />
            </Button>
            <Button
              type="button"
              variant="outline"
              size="icon"
              aria-label={`Bajar ${label} ${index + 1}`}
              onClick={() => moveItem(index, 1)}
              disabled={index === items.length - 1}
              className="h-9 w-9 shrink-0 border-slate-700 bg-slate-800/50 text-slate-300"
            >
              <ArrowDown className="h-3.5 w-3.5" />
            </Button>
            <Button
              type="button"
              variant="outline"
              size="icon"
              aria-label={`Eliminar ${label} ${index + 1}`}
              onClick={() => removeItem(index)}
              className="h-9 w-9 shrink-0 border-slate-700 bg-slate-800/50 text-red-400 hover:text-red-500"
            >
              <Trash2 className="h-3.5 w-3.5" />
            </Button>
          </div>
          <Textarea
            aria-label={`${textFieldLabel} de ${label} ${index + 1}`}
            placeholder={textPlaceholder}
            value={item.text}
            onChange={(e) => updateItem(index, { text: e.target.value })}
            className="bg-slate-800 border-slate-700 text-slate-100 min-h-[60px]"
          />
        </div>
      ))}

      <Button
        type="button"
        variant="outline"
        size="sm"
        onClick={addItem}
        className="w-fit gap-2 border-slate-700 bg-slate-800/50 text-slate-300"
      >
        <Plus className="h-3.5 w-3.5" />
        Agregar {label}
      </Button>
    </div>
  )
}

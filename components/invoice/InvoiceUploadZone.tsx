"use client"

import { useRef, useState, useCallback } from "react"
import { Upload, Camera, FileImage, AlertCircle } from "lucide-react"
import { cn } from "@/lib/utils"
import { Button } from "@/components/ui/button"

interface Props {
  onFileSelected: (file: File) => void
  disabled?: boolean
}

const ACCEPTED_TYPES = ["image/jpeg", "image/jpg", "image/png", "image/webp", "image/heic"]
const MAX_SIZE_MB    = 20

export function InvoiceUploadZone({ onFileSelected, disabled }: Props) {
  const fileRef    = useRef<HTMLInputElement>(null)
  const cameraRef  = useRef<HTMLInputElement>(null)
  const [dragOver, setDragOver] = useState(false)
  const [error,    setError]    = useState<string | null>(null)

  const validate = useCallback((file: File): string | null => {
    if (!ACCEPTED_TYPES.includes(file.type.toLowerCase())) {
      return `Tipo no soportado: ${file.type || "desconocido"}. Usá JPEG, PNG o WEBP.`
    }
    if (file.size > MAX_SIZE_MB * 1024 * 1024) {
      return `El archivo pesa más de ${MAX_SIZE_MB} MB.`
    }
    return null
  }, [])

  const handleFile = useCallback((file: File | null) => {
    if (!file) return
    const err = validate(file)
    if (err) { setError(err); return }
    setError(null)
    onFileSelected(file)
  }, [validate, onFileSelected])

  const onDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault()
    setDragOver(false)
    handleFile(e.dataTransfer.files[0] ?? null)
  }, [handleFile])

  return (
    <div className="flex flex-col gap-3">
      {/* Drop zone */}
      <div
        onDragOver={(e) => { e.preventDefault(); setDragOver(true) }}
        onDragLeave={() => setDragOver(false)}
        onDrop={onDrop}
        className={cn(
          "relative flex flex-col items-center justify-center gap-3 rounded-xl border-2 border-dashed p-8",
          "transition-all duration-200 cursor-pointer select-none",
          dragOver
            ? "border-primary bg-primary/10"
            : "border-border hover:border-primary/50 hover:bg-accent/30",
          disabled && "pointer-events-none opacity-50",
        )}
        onClick={() => fileRef.current?.click()}
      >
        <div className="flex h-14 w-14 items-center justify-center rounded-full bg-primary/10">
          <FileImage className="h-7 w-7 text-primary" />
        </div>
        <div className="text-center">
          <p className="text-sm font-medium text-foreground">
            Arrastrá la factura aquí o hacé click para elegir
          </p>
          <p className="text-xs text-muted-foreground mt-1">
            JPEG · PNG · WEBP · HEIC · máx {MAX_SIZE_MB} MB
          </p>
        </div>
        <input
          ref={fileRef}
          type="file"
          accept={ACCEPTED_TYPES.join(",")}
          className="hidden"
          disabled={disabled}
          onChange={(e) => handleFile(e.target.files?.[0] ?? null)}
        />
      </div>

      {/* Camera capture (mobile) */}
      <div className="flex items-center gap-2">
        <div className="flex-1 border-t border-border" />
        <span className="text-[11px] text-muted-foreground">o</span>
        <div className="flex-1 border-t border-border" />
      </div>

      <Button
        type="button"
        variant="outline"
        className="w-full gap-2"
        disabled={disabled}
        onClick={() => cameraRef.current?.click()}
      >
        <Camera className="h-4 w-4" />
        Capturar con cámara
      </Button>
      <input
        ref={cameraRef}
        type="file"
        accept="image/*"
        capture="environment"
        className="hidden"
        disabled={disabled}
        onChange={(e) => handleFile(e.target.files?.[0] ?? null)}
      />

      {/* Tip */}
      <div className="rounded-lg border border-border bg-accent/20 p-3">
        <div className="flex items-start gap-2">
          <Upload className="h-3.5 w-3.5 text-muted-foreground mt-0.5 shrink-0" />
          <p className="text-[11px] text-muted-foreground leading-relaxed">
            <span className="font-medium text-foreground">Consejo:</span> Para mejores resultados usá una foto con buena iluminación,
            sin sombras y enfocada. La IA puede leer facturas A/B/C, tickets y remitos.
          </p>
        </div>
      </div>

      {error && (
        <div className="flex items-center gap-2 rounded-lg border border-red-500/30 bg-red-500/10 px-3 py-2">
          <AlertCircle className="h-4 w-4 text-red-400 shrink-0" />
          <p className="text-xs text-red-400">{error}</p>
        </div>
      )}
    </div>
  )
}
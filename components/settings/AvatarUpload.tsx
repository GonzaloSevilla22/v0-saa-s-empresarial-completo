"use client"

import { useRef, useState } from "react"
import { createClient } from "@/lib/supabase/client"
import { Button } from "@/components/ui/button"
import { Camera, Loader2, Trash2 } from "lucide-react"
import { toast } from "sonner"

const BUCKET      = "avatars"
const MAX_BYTES   = 2 * 1024 * 1024          // 2 MB
const ALLOWED     = ["image/jpeg", "image/png", "image/webp", "image/gif"]

interface AvatarUploadProps {
  userId:   string
  currentUrl?: string
  onUpload: (url: string | null) => void   // null = avatar removed
}

export function AvatarUpload({ userId, currentUrl, onUpload }: AvatarUploadProps) {
  const inputRef          = useRef<HTMLInputElement>(null)
  const [preview, setPreview]   = useState<string | null>(currentUrl ?? null)
  const [uploading, setUploading] = useState(false)

  async function handleFile(file: File) {
    // ── Client-side validation ────────────────────────────────────────────────
    if (!ALLOWED.includes(file.type)) {
      toast.error("Solo se permiten imágenes JPEG, PNG, WebP o GIF")
      return
    }
    if (file.size > MAX_BYTES) {
      toast.error("La imagen no puede superar 2 MB")
      return
    }

    setUploading(true)
    try {
      const supabase = createClient()
      const ext      = file.name.split(".").pop() ?? "jpg"
      const path     = `${userId}/avatar.${ext}`

      // Use upsert so re-uploads don't create duplicate objects
      const { error: uploadError } = await supabase.storage
        .from(BUCKET)
        .upload(path, file, { upsert: true, contentType: file.type })

      if (uploadError) throw uploadError

      const { data } = supabase.storage.from(BUCKET).getPublicUrl(path)
      // Cache-bust so the browser doesn't show the old image
      const publicUrl = `${data.publicUrl}?t=${Date.now()}`

      setPreview(publicUrl)
      onUpload(publicUrl)
      toast.success("Avatar actualizado")
    } catch (err: any) {
      toast.error(err.message || "Error al subir la imagen")
    } finally {
      setUploading(false)
    }
  }

  async function handleRemove() {
    setUploading(true)
    try {
      const supabase = createClient()
      // Try deleting all common extensions — ignore errors (file may not exist)
      await Promise.allSettled(
        ["jpg", "jpeg", "png", "webp", "gif"].map(ext =>
          supabase.storage.from(BUCKET).remove([`${userId}/avatar.${ext}`])
        )
      )
      setPreview(null)
      onUpload(null)
      toast.success("Avatar eliminado")
    } catch (err: any) {
      toast.error(err.message || "Error al eliminar el avatar")
    } finally {
      setUploading(false)
    }
  }

  return (
    <div className="flex flex-col items-center gap-3">
      {/* ── Avatar circle ─────────────────────────────────────────────────── */}
      <div className="relative">
        <div className="h-24 w-24 rounded-full bg-secondary border-2 border-border overflow-hidden flex items-center justify-center">
          {preview ? (
            <img
              src={preview}
              alt="Avatar"
              className="h-full w-full object-cover"
            />
          ) : (
            <Camera className="h-8 w-8 text-muted-foreground" />
          )}
          {uploading && (
            <div className="absolute inset-0 flex items-center justify-center bg-black/50 rounded-full">
              <Loader2 className="h-6 w-6 animate-spin text-white" />
            </div>
          )}
        </div>
      </div>

      {/* ── Controls ──────────────────────────────────────────────────────── */}
      <div className="flex gap-2">
        <Button
          type="button"
          variant="outline"
          size="sm"
          disabled={uploading}
          onClick={() => inputRef.current?.click()}
          className="border-border text-xs"
        >
          <Camera className="h-3 w-3 mr-1.5" />
          {preview ? "Cambiar foto" : "Subir foto"}
        </Button>

        {preview && (
          <Button
            type="button"
            variant="ghost"
            size="sm"
            disabled={uploading}
            onClick={handleRemove}
            className="text-xs text-muted-foreground hover:text-destructive"
          >
            <Trash2 className="h-3 w-3 mr-1.5" />
            Eliminar
          </Button>
        )}
      </div>

      <p className="text-[10px] text-muted-foreground">
        JPEG, PNG, WebP o GIF · Máx. 2 MB
      </p>

      {/* Hidden file input */}
      <input
        ref={inputRef}
        type="file"
        accept={ALLOWED.join(",")}
        className="hidden"
        onChange={e => {
          const file = e.target.files?.[0]
          if (file) handleFile(file)
          e.target.value = ""  // allow re-selecting the same file
        }}
      />
    </div>
  )
}

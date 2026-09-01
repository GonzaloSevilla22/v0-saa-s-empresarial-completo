import { getInitials } from "@/lib/helpers/user-helpers"
import { cn } from "@/lib/utils"

interface AdvisorAvatarProps {
  photoUrl?: string | null
  name: string
  className?: string
}

/**
 * Avatar del perfil de asesor con degradación a iniciales (design.md D8):
 * sin `photoUrl`, rinde las iniciales derivadas del nombre ocupando las
 * mismas dimensiones que tendría la foto — el layout no cambia según haya
 * o no imagen cargada.
 *
 * Usa un `<img>` nativo en vez de `@radix-ui/react-avatar`: el primitivo de
 * Radix difiere el render de `AvatarImage` hasta que el evento `load` del
 * DOM dispara, algo que jsdom (entorno de test) nunca emite — el `<img>`
 * quedaría invisible en cualquier test sin mockear timers/eventos de carga.
 * Mismo tamaño fijo (`h-24 w-24`) en ambas ramas, así el layout no salta.
 */
export function AdvisorAvatar({ photoUrl, name, className }: AdvisorAvatarProps) {
  const initials = getInitials(name, "?")

  if (photoUrl) {
    return (
      <img
        src={photoUrl}
        alt={name}
        className={cn(
          "h-24 w-24 shrink-0 rounded-full border border-border object-cover",
          className
        )}
      />
    )
  }

  return (
    <div
      role="img"
      aria-label={name}
      className={cn(
        "flex h-24 w-24 shrink-0 items-center justify-center rounded-full border border-border bg-primary/10 text-2xl font-semibold text-primary",
        className
      )}
    >
      {initials}
    </div>
  )
}

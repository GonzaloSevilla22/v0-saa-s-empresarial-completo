"use client"

/**
 * InvitationAcceptance — la pantalla pública /invitacion/[token] (multiusuario-operativo tanda C, D12).
 *
 * Se llega por el link del email. Cuatro estados, todos ligados a la IDENTIDAD de quien mira:
 *
 *   1. SIN sesión   -> mensaje genérico (OQ-5 a: sin el nombre del negocio ni el de quien invita) con
 *                      «Ingresar» y «Crear cuenta», que al completarse vuelven a ESTA invitación
 *                      (`?next=/invitacion/<token>`, allow-list estrecha). No consulta la vista previa.
 *   2. Identidad correcta -> la vista previa (negocio, quién invita, roles, vencimiento) y «Aceptar».
 *                      Aceptar crea la membresía, deja el negocio como cuenta ACTIVA (`adoptActiveAccount`:
 *                      renueva el token ante el proveedor, limpia la caché, avisa a las otras pestañas y
 *                      lleva al Tablero) y da la bienvenida con los roles.
 *   3. Otra identidad / vencida / revocada / usada / inexistente -> UN solo mensaje, indistinguible
 *                      entre esos casos (la base responde LO MISMO: P0404), con «Cerrar sesión e ingresar
 *                      con otro email». Nunca confirma que el token existe.
 *   4. Ya es miembro -> «Ya sos parte de {negocio}» con «Cambiar a esa cuenta».
 *
 * El token NO se imprime nunca en pantalla ni viaja a ningún tercero: la ruta sale con
 * `Referrer-Policy: no-referrer` y `noindex` (`lib/supabase/middleware.ts`).
 */

import { useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { toast } from "sonner"
import { AlertCircle, Building2, CheckCircle2, Loader2, MailOpen, ShieldAlert } from "lucide-react"
import { useAuth } from "@/contexts/auth-context"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { Card, CardContent, CardDescription, CardFooter, CardHeader } from "@/components/ui/card"
import { useAcceptInvitation, useInvitationPreview, type InvitationPreview } from "@/hooks/data/use-invitations"
import { classifyInvitationFailure, type InvitationFailure } from "@/lib/invitation-errors"
import { invitationPath } from "@/lib/auth/invitation-next"

/** El texto único de «no disponible»: el mismo para cualquier causa que la base no distingue. */
export const INVITATION_UNAVAILABLE_MESSAGE =
  "Esta invitación no está disponible para tu usuario: puede haber vencido o ser para otro email."

function Shell({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex min-h-svh items-center justify-center bg-background p-4">
      <div className="flex w-full max-w-md flex-col items-center gap-6">
        <div className="flex flex-col items-center gap-3">
          <div className="flex h-14 w-14 items-center justify-center overflow-hidden rounded-xl">
            <img src="/aliadata-logo.png" alt="" className="h-full w-full object-contain" />
          </div>
          <p className="text-lg font-bold tracking-tight text-foreground">ALIADATA</p>
        </div>
        {children}
      </div>
    </div>
  )
}

/**
 * El título de cada estado. `CardTitle` de shadcn renderiza un <div>: la pantalla pública se quedaba sin ningún
 * encabezado para un lector de pantalla (a11y: 1.3.1 / 2.4.6). Un <h1> por estado, con la misma tipografía.
 */
function Heading({ children }: { children: React.ReactNode }) {
  return <h1 className="text-xl font-semibold leading-tight tracking-tight text-card-foreground">{children}</h1>
}

function formatExpiry(iso: string): string {
  const date = new Date(iso)
  return Number.isNaN(date.getTime()) ? "" : date.toLocaleDateString("es-AR")
}

export function InvitationAcceptance({ token }: { token: string }) {
  const { user, logout, adoptActiveAccount, switchAccount } = useAuth()
  const router = useRouter()
  const returnTo = invitationPath(token)
  const signedIn = !!user

  const preview = useInvitationPreview(token, signedIn)
  const accept = useAcceptInvitation(token)
  // Lo que pasó al ACEPTAR (la vista previa ya andaba): puede cambiar la pantalla sin recargar.
  const [acceptFailure, setAcceptFailure] = useState<InvitationFailure | null>(null)
  const [adoptFailed, setAdoptFailed] = useState(false)
  // Entre que la base aceptó y que el cambio de cuenta termina (renovar el token tarda) el botón sigue ocupado:
  // sin esto quedaba habilitado un instante y un segundo clic habría pegado contra una invitación ya usada.
  const [adopting, setAdopting] = useState(false)
  const [switching, setSwitching] = useState(false)

  const data: InvitationPreview | undefined = preview.data
  const businessName = data?.account_display_name ?? "este negocio"
  const welcome = data
    ? `Te sumaste a ${data.account_display_name}${data.role_labels.length > 0 ? ` como ${data.role_labels.join(", ")}` : ""}`
    : "Te sumaste al negocio"

  async function runAdopt() {
    setAdoptFailed(false)
    setAdopting(true)
    try {
      await adoptActiveAccount({ message: welcome })
    } catch {
      // La membresía YA existe: lo que falló es el cambio de cuenta. Se ofrece reintentarlo, no volver a aceptar.
      setAdoptFailed(true)
      setAdopting(false)
    }
  }

  async function handleAccept() {
    setAcceptFailure(null)
    try {
      await accept.mutateAsync()
    } catch (error) {
      const failure = classifyInvitationFailure(error)
      if (failure === "other") toast.error("No pudimos aceptar la invitación. Probá de nuevo.")
      else setAcceptFailure(failure)
      return
    }
    await runAdopt()
  }

  async function handleSwitch() {
    if (!data) return
    setSwitching(true)
    try {
      await switchAccount(data.account_id)
    } catch {
      // switchAccount ya avisó con un toast y recargó la lista de cuentas.
    } finally {
      setSwitching(false)
    }
  }

  // ── 1. Sin sesión ──────────────────────────────────────────────────────────
  if (!signedIn) {
    const next = encodeURIComponent(returnTo)
    return (
      <Shell>
        <Card className="w-full border-border bg-card">
          <CardHeader className="items-center text-center">
            <div className="mb-1 flex h-12 w-12 items-center justify-center rounded-full bg-primary/10 text-primary">
              <MailOpen className="h-6 w-6" aria-hidden="true" />
            </div>
            <Heading>Tenés una invitación</Heading>
            <CardDescription className="text-sm text-muted-foreground">
              Tenés una invitación para sumarte a un negocio en ALIADATA. Ingresá o creá tu cuenta con el email al
              que te llegó.
            </CardDescription>
          </CardHeader>
          <CardFooter className="flex flex-col gap-2 sm:flex-row">
            <Button asChild className="min-h-11 w-full sm:flex-1">
              <Link href={`/auth/login?next=${next}`}>Ingresar</Link>
            </Button>
            <Button asChild variant="outline" className="min-h-11 w-full border-border sm:flex-1">
              <Link href={`/auth/register?next=${next}`}>Crear cuenta</Link>
            </Button>
          </CardFooter>
        </Card>
      </Shell>
    )
  }

  // ── Cargando la vista previa ───────────────────────────────────────────────
  if (preview.isPending) {
    return (
      <Shell>
        <Card className="w-full border-border bg-card" role="status" aria-live="polite">
          <CardContent className="flex items-center justify-center gap-3 py-10 text-sm text-muted-foreground">
            <Loader2 className="h-4 w-4 animate-spin" aria-hidden="true" />
            Cargando la invitación…
          </CardContent>
        </Card>
      </Shell>
    )
  }

  // ── Aceptó, pero no pudo cambiar de cuenta ─────────────────────────────────
  if (adoptFailed) {
    return (
      <Shell>
        <Card className="w-full border-border bg-card" role="alert">
          <CardHeader className="items-center text-center">
            <div className="mb-1 flex h-12 w-12 items-center justify-center rounded-full bg-primary/10 text-primary">
              <CheckCircle2 className="h-6 w-6" aria-hidden="true" />
            </div>
            <Heading>Aceptaste la invitación</Heading>
            <CardDescription className="text-sm text-muted-foreground">
              Ya sos parte de {businessName}, pero no pudimos pasarte a esa cuenta. Probá de nuevo.
            </CardDescription>
          </CardHeader>
          <CardFooter>
            <Button className="min-h-11 w-full" onClick={() => void runAdopt()}>
              Cambiar a esa cuenta
            </Button>
          </CardFooter>
        </Card>
      </Shell>
    )
  }

  // ── Fallos ─────────────────────────────────────────────────────────────────
  const loadFailure: InvitationFailure | null = preview.isError ? classifyInvitationFailure(preview.error) : null
  const failure = acceptFailure ?? loadFailure

  if (failure === "unavailable") {
    return (
      <Shell>
        <Card className="w-full border-border bg-card" role="alert">
          <CardHeader className="items-center text-center">
            <div className="mb-1 flex h-12 w-12 items-center justify-center rounded-full bg-destructive/10 text-destructive">
              <ShieldAlert className="h-6 w-6" aria-hidden="true" />
            </div>
            <Heading>Invitación no disponible</Heading>
            <CardDescription className="text-sm text-muted-foreground">{INVITATION_UNAVAILABLE_MESSAGE}</CardDescription>
          </CardHeader>
          <CardFooter className="flex flex-col gap-2">
            <Button className="min-h-11 w-full" onClick={() => void logout({ returnTo })}>
              Cerrar sesión e ingresar con otro email
            </Button>
            <Button variant="ghost" className="min-h-11 w-full text-muted-foreground" onClick={() => router.push("/dashboard")}>
              Ir al Tablero
            </Button>
          </CardFooter>
        </Card>
      </Shell>
    )
  }

  if (failure === "quota") {
    return (
      <Shell>
        <Card className="w-full border-border bg-card" role="alert">
          <CardHeader className="items-center text-center">
            <div className="mb-1 flex h-12 w-12 items-center justify-center rounded-full bg-destructive/10 text-destructive">
              <AlertCircle className="h-6 w-6" aria-hidden="true" />
            </div>
            <Heading>El negocio llegó a su límite</Heading>
            <CardDescription className="text-sm text-muted-foreground">
              {businessName} alcanzó el máximo de usuarios de su plan. Pedile a quien te invitó que libere un lugar o
              amplíe el plan, y volvé a abrir este link.
            </CardDescription>
          </CardHeader>
          <CardFooter>
            <Button variant="outline" className="min-h-11 w-full border-border" onClick={() => router.push("/dashboard")}>
              Ir al Tablero
            </Button>
          </CardFooter>
        </Card>
      </Shell>
    )
  }

  if (failure === "other") {
    return (
      <Shell>
        <Card className="w-full border-border bg-card" role="alert">
          <CardHeader className="items-center text-center">
            <div className="mb-1 flex h-12 w-12 items-center justify-center rounded-full bg-destructive/10 text-destructive">
              <AlertCircle className="h-6 w-6" aria-hidden="true" />
            </div>
            <Heading>No pudimos cargar la invitación</Heading>
            <CardDescription className="text-sm text-muted-foreground">
              Hubo un problema de conexión. Probá de nuevo en unos segundos.
            </CardDescription>
          </CardHeader>
          <CardFooter>
            <Button className="min-h-11 w-full" onClick={() => void preview.refetch()}>
              Reintentar
            </Button>
          </CardFooter>
        </Card>
      </Shell>
    )
  }

  // ── 4. Ya es miembro (por la vista previa o porque aceptar devolvió 409) ───
  if (failure === "already-member" || data?.already_member) {
    return (
      <Shell>
        <Card className="w-full border-border bg-card">
          <CardHeader className="items-center text-center">
            <div className="mb-1 flex h-12 w-12 items-center justify-center rounded-full bg-primary/10 text-primary">
              <Building2 className="h-6 w-6" aria-hidden="true" />
            </div>
            <Heading>Ya sos parte de {businessName}</Heading>
            <CardDescription className="text-sm text-muted-foreground">
              Esta invitación es para una cuenta a la que ya pertenecés. Podés pasar a ella cuando quieras.
            </CardDescription>
          </CardHeader>
          <CardFooter className="flex flex-col gap-2">
            <Button className="min-h-11 w-full" disabled={switching || !data} onClick={() => void handleSwitch()}>
              {switching && <Loader2 className="mr-2 h-4 w-4 animate-spin" aria-hidden="true" />}
              Cambiar a esa cuenta
            </Button>
            <Button variant="ghost" className="min-h-11 w-full text-muted-foreground" onClick={() => router.push("/dashboard")}>
              Ir al Tablero
            </Button>
          </CardFooter>
        </Card>
      </Shell>
    )
  }

  // ── 2. Identidad correcta: la vista previa ─────────────────────────────────
  if (!data) return null
  const expiry = formatExpiry(data.expires_at)
  return (
    <Shell>
      <Card className="w-full border-border bg-card">
        <CardHeader className="items-center text-center">
          <div className="mb-1 flex h-12 w-12 items-center justify-center rounded-full bg-primary/10 text-primary">
            <Building2 className="h-6 w-6" aria-hidden="true" />
          </div>
          <Heading>Te invitaron a sumarte a {data.account_display_name}</Heading>
          <CardDescription className="text-sm text-muted-foreground">
            Revisá los datos y aceptá para empezar a trabajar en este negocio.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-3 text-sm">
            <dt className="text-muted-foreground">Te invita</dt>
            <dd className="font-medium text-foreground">{data.inviter_name}</dd>
            <dt className="text-muted-foreground">Roles</dt>
            <dd className="flex flex-wrap gap-1.5">
              {data.role_labels.map((label) => (
                <Badge key={label} variant="secondary" className="text-xs">
                  {label}
                </Badge>
              ))}
            </dd>
            {expiry && (
              <>
                <dt className="text-muted-foreground">Vence</dt>
                <dd className="font-medium text-foreground">{expiry}</dd>
              </>
            )}
          </dl>
          <p className="mt-4 text-xs text-muted-foreground">
            Conservás tu cuenta propia: vas a poder pasar de una a otra desde el menú.
          </p>
        </CardContent>
        <CardFooter className="flex flex-col gap-2">
          <Button className="min-h-11 w-full" disabled={accept.isPending || adopting} onClick={() => void handleAccept()}>
            {accept.isPending || adopting ? (
              <>
                <Loader2 className="mr-2 h-4 w-4 animate-spin" aria-hidden="true" />
                Aceptando…
              </>
            ) : (
              "Aceptar invitación"
            )}
          </Button>
          <Button variant="ghost" className="min-h-11 w-full text-muted-foreground" disabled={accept.isPending || adopting} onClick={() => router.push("/dashboard")}>
            Ahora no
          </Button>
        </CardFooter>
      </Card>
    </Shell>
  )
}

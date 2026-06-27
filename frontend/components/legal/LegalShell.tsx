import Link from "next/link"
import { ArrowLeft } from "lucide-react"
import { TERMS_VERSION, TERMS_EFFECTIVE_DATE } from "@/lib/legal"

/**
 * Marco visual compartido por las páginas legales públicas (/legal/*).
 * Muestra el identificador de versión + fecha efectiva (consistente con
 * `TERMS_VERSION`) y una marca visible de "borrador" pendiente de revisión legal.
 */
export function LegalShell({
  title,
  children,
}: {
  title: string
  children: React.ReactNode
}) {
  return (
    <div className="min-h-svh bg-background px-4 py-10">
      <div className="mx-auto w-full max-w-3xl">
        <Link
          href="/auth/register"
          className="mb-6 inline-flex items-center gap-1.5 text-sm text-muted-foreground transition-colors hover:text-primary"
        >
          <ArrowLeft className="h-3.5 w-3.5" />
          Volver al registro
        </Link>

        <header className="mb-6 border-b border-border pb-6">
          <p className="text-sm text-muted-foreground">ALIADATA — Emprender es Inteligente</p>
          <h1 className="mt-1 text-3xl font-bold tracking-tight text-foreground">{title}</h1>
          <p className="mt-2 text-xs text-muted-foreground">
            Versión <span className="font-medium text-foreground">{TERMS_VERSION}</span> · Vigente
            desde el {TERMS_EFFECTIVE_DATE}
          </p>

          <div
            role="note"
            className="mt-4 rounded-md border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-200"
          >
            <strong>Borrador.</strong> Este documento es un borrador estándar pendiente de
            revisión legal. No constituye asesoramiento jurídico ni la versión definitiva.
          </div>
        </header>

        <article className="space-y-5 text-sm leading-relaxed text-foreground [&_h2]:mt-8 [&_h2]:text-lg [&_h2]:font-semibold [&_h2]:text-foreground [&_p]:text-muted-foreground [&_li]:text-muted-foreground [&_ul]:list-disc [&_ul]:space-y-1 [&_ul]:pl-5 [&_a]:text-primary [&_a]:underline-offset-4 hover:[&_a]:underline">
          {children}
        </article>

        <footer className="mt-10 border-t border-border pt-6 text-xs text-muted-foreground">
          <p>
            ¿Dudas sobre el tratamiento de tus datos? Escribinos a{" "}
            <a href="mailto:soporte@alia-data.com">soporte@alia-data.com</a>.
          </p>
          <p className="mt-2">
            Consultá también la{" "}
            <Link href="/legal/privacidad">Política de Privacidad</Link> y los{" "}
            <Link href="/legal/terminos">Términos y Condiciones</Link>.
          </p>
        </footer>
      </div>
    </div>
  )
}

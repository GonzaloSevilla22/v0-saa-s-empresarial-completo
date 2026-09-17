import type { Metadata, Viewport } from "next"
import { cookies, headers } from "next/headers"
import { Geist, Geist_Mono } from "next/font/google"
import { AuthProvider } from "@/contexts/auth-context"
import { ThemeProvider } from "@/components/theme-provider"
import { ThemeSync } from "@/components/theme-sync"
import { QueryProvider } from "@/providers/query-provider"
import { Toaster } from "sonner"

import "./globals.css"

const _geist = Geist({ subsets: ["latin"] })
const _geistMono = Geist_Mono({ subsets: ["latin"] })

export const metadata: Metadata = {
  title: "ALIADATA - Emprender es Inteligente",
  description: "Plataforma SaaS de gestión empresarial para emprendedores con inteligencia artificial",
  applicationName: "Aliadata",
  manifest: "/manifest.webmanifest",
  appleWebApp: {
    capable: true,
    title: "Aliadata",
    statusBarStyle: "black-translucent",
  },
  icons: {
    icon: [
      { url: "/icons/icon-192.png", sizes: "192x192", type: "image/png" },
      { url: "/icons/icon-512.png", sizes: "512x512", type: "image/png" },
    ],
    apple: [
      { url: "/icons/apple-touch-icon.png", sizes: "180x180", type: "image/png" },
    ],
    shortcut: "/icons/icon-192.png",
  },
}

export const viewport: Viewport = {
  themeColor: "#09090b",
  width: "device-width",
  initialScale: 1,
  maximumScale: 5,
}

export default async function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode
}>) {
  // Read the theme cookie server-side so the initial SSR render matches
  // the user's saved preference — prevents the light→dark flash on reload.
  const cookieStore = await cookies()
  const savedTheme = cookieStore.get("ui:theme")?.value ?? "dark"

  // auth-hardening-jwt-cookies (D3, task 21.7): el nonce de la CSP de ESTA
  // petición, puesto por el middleware. `next-themes` inyecta un `<script>` en
  // línea para evitar el parpadeo de tema y, con `disableTransitionOnChange`, un
  // `<style>`: bajo `'strict-dynamic'` sin `'unsafe-inline'`, sin nonce ese script
  // no se ejecuta y la página abre en claro para saltar a oscuro al hidratar.
  //
  // Se lee acá, en el servidor, porque `components/theme-provider.tsx` es
  // `"use client"` y sólo propaga props: no puede leer encabezados por su cuenta.
  // Los scripts propios de Next NO dependen de esto — su nonce lo saca del
  // encabezado de petición `content-security-policy` (ver el middleware).
  const nonce = (await headers()).get("x-nonce") ?? undefined

  return (
    <html lang="es" suppressHydrationWarning>
      <body className="font-sans antialiased">
        <ThemeProvider
          attribute="class"
          defaultTheme={savedTheme}
          enableSystem
          disableTransitionOnChange
          nonce={nonce}
        >
          {/* Keeps ui:theme cookie in sync when the user changes the theme */}
          <ThemeSync />
          <QueryProvider>
            <AuthProvider>
              {children}
              <Toaster
                theme="dark"
                richColors
                position="bottom-right"
              />
            </AuthProvider>
          </QueryProvider>
        </ThemeProvider>
      </body>
    </html>
  )
}

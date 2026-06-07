import type { Metadata, Viewport } from "next"
import { cookies } from "next/headers"
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

  return (
    <html lang="es" suppressHydrationWarning>
      <body className="font-sans antialiased">
        <ThemeProvider
          attribute="class"
          defaultTheme={savedTheme}
          enableSystem
          disableTransitionOnChange
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

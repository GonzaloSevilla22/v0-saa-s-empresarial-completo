import type { Metadata, Viewport } from 'next'
import { Geist, Geist_Mono } from 'next/font/google'
import { AuthProvider } from '@/contexts/auth-context'
import { Toaster } from 'sonner'

import './globals.css'

const _geist = Geist({ subsets: ['latin'] })
const _geistMono = Geist_Mono({ subsets: ['latin'] })

export const metadata: Metadata = {
  title: 'EIE - Emprender es Inteligente',
  description: 'Plataforma SaaS de gestión empresarial para emprendedores con inteligencia artificial',
}

export const viewport: Viewport = {
  themeColor: '#09090b',
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode
}>) {
  return (
    <html lang="es" className="dark">
      <body className="font-sans antialiased">
        <AuthProvider>
          {children}
          <Toaster
            theme="dark"
            richColors
            position="bottom-right"
          />
        </AuthProvider>
      </body>
    </html>
  )
}

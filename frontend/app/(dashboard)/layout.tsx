import { cookies } from "next/headers"
import { SidebarProvider, SidebarInset } from "@/components/ui/sidebar"
import { AppSidebar } from "@/components/app-sidebar"
import { BreadcrumbNav } from "@/components/dashboard/breadcrumb-nav"
import { IdleTimeoutProvider } from "@/components/auth/IdleTimeoutProvider"

export default async function DashboardLayout({
  children,
}: {
  children: React.ReactNode
}) {
  // Read sidebar preference server-side so SidebarProvider's initial render
  // matches the user's saved state — prevents the collapsed→expanded flash.
  const cookieStore = await cookies()
  const sidebarCookie = cookieStore.get("ui:sidebar")?.value
  // Default open unless the user explicitly saved it as closed
  const defaultOpen = sidebarCookie !== "false"

  return (
    <SidebarProvider defaultOpen={defaultOpen}>
      {/* IdleTimeoutProvider is a Client Component — mounted only inside the
          authenticated dashboard layout so idle tracking never runs on
          public/auth pages (design.md §Decision 8). */}
      <IdleTimeoutProvider />
      <AppSidebar />
      <SidebarInset>
        <BreadcrumbNav />
        <div className="flex-1 overflow-auto p-4 md:p-6">
          {children}
        </div>
      </SidebarInset>
    </SidebarProvider>
  )
}

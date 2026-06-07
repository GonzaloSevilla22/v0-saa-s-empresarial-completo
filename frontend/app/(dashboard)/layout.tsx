import { cookies } from "next/headers"
import { DataProvider } from "@/contexts/data-context"
import { SidebarProvider, SidebarInset } from "@/components/ui/sidebar"
import { AppSidebar } from "@/components/app-sidebar"
import { BreadcrumbNav } from "@/components/dashboard/breadcrumb-nav"

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
    <DataProvider>
      <SidebarProvider defaultOpen={defaultOpen}>
        <AppSidebar />
        <SidebarInset>
          <BreadcrumbNav />
          <div className="flex-1 overflow-auto p-4 md:p-6">
            {children}
          </div>
        </SidebarInset>
      </SidebarProvider>
    </DataProvider>
  )
}

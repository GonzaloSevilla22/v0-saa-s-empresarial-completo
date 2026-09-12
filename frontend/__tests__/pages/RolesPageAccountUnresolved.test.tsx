/**
 * /organizacion/roles — fix defensivo del MAJOR-1 (v3-rbac-multirole Parte
 * C, ronda 3 adversarial).
 *
 * Con `accountId` sin resolver (auth-context no encontró ninguna membresía
 * -- ver `auth-context-membership.test.tsx`), `useMembers` queda
 * `enabled: false`: `isLoading` nunca pasa por `true` y `members` cae en
 * `[]` por default. Sin este fix la pantalla mostraba "Sin miembros." (un
 * estado vacío LEGÍTIMO) para lo que en realidad es un fallo de resolución
 * de cuenta, y ofrecía igual el CTA "Invitar" porque `accountRole` cae al
 * fallback `"owner"` en auth-context cuando la membresía es null.
 *
 * Lo que este archivo fija: con accountId falsy, la pantalla NUNCA muestra
 * "Sin miembros." ni el CTA de gestión ("Invitar"), y en cambio muestra un
 * estado "No se pudo resolver tu cuenta".
 *
 * Cycle: RED → GREEN → TRIANGULATE
 * Mock: @/contexts/auth-context, @/hooks/useOrgRole, @/hooks/data/use-members,
 *       @/hooks/data/use-role-catalog
 */
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import type { OrgRole } from "@/lib/types"
import type { MemberRow } from "@/hooks/data/use-members"

// ── Estado controlable por test ─────────────────────────────────────────────
let accountIdFixture: string | undefined = ""
let callerRoleFixture: OrgRole | null = "owner"
let membersFixture: MemberRow[] = []

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { id: "user-1", accountId: accountIdFixture, accountRole: callerRoleFixture } }),
}))

vi.mock("@/hooks/useOrgRole", () => ({
  useOrgRole: () => ({ role: callerRoleFixture, roles: callerRoleFixture ? [callerRoleFixture] : [], isWriter: true, isLoading: false }),
}))

vi.mock("@/hooks/data/use-members", () => ({
  useMembers: (accountId: string | null) => ({
    members: accountId ? membersFixture : [],
    isLoading: false,
    isError: false,
    assignRole: vi.fn(),
    revokeRole: vi.fn(),
    removeMember: vi.fn(),
    assignRoleMutation: { isPending: false },
    revokeRoleMutation: { isPending: false },
    removeMemberMutation: { isPending: false },
  }),
}))

vi.mock("@/hooks/data/use-role-catalog", () => ({
  useRoleCatalog: () => ({ data: [], isLoading: false }),
  resolveRoleLabel: (_catalog: unknown, code: string) => code,
}))

// Importado DESPUÉS de los vi.mock (hoisted igual, pero mantiene el orden de lectura claro).
import RolesPage from "@/app/(dashboard)/organizacion/roles/page"

describe("/organizacion/roles — accountId sin resolver (fix defensivo MAJOR-1)", () => {
  it("NO muestra \"Sin miembros.\" ni el CTA de gestión; muestra el estado de cuenta no resuelta", () => {
    accountIdFixture = ""
    callerRoleFixture = "owner"
    membersFixture = []

    render(<RolesPage />)

    expect(screen.getByText("No se pudo resolver tu cuenta.")).toBeInTheDocument()
    expect(screen.queryByText("Sin miembros.")).not.toBeInTheDocument()
    expect(screen.queryByText("Invitar")).not.toBeInTheDocument()
  })

  it("(triangulate) accountId resuelto: la pantalla vuelve al comportamiento normal", () => {
    accountIdFixture = "acc-1"
    callerRoleFixture = "owner"
    membersFixture = []

    render(<RolesPage />)

    expect(screen.queryByText("No se pudo resolver tu cuenta.")).not.toBeInTheDocument()
    expect(screen.getByText("Sin miembros.")).toBeInTheDocument()
    expect(screen.getByText("Invitar")).toBeInTheDocument()
  })
})

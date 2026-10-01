/**
 * sidebar-menu-grupos — decisión del PO (2026-09-30): la etiqueta en español es
 * "IA", no "AI". El panel técnico `/admin/analytics` titula su gráfico de
 * insights "Distribución de Consejos IA", igual que el resto de la app.
 *
 * Los gráficos se reemplazan por stubs y la carga de datos por un payload
 * mínimo; el test sólo mira el encabezado de esa sección.
 */

import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"

vi.mock("@/hooks/auth/use-admin-gate", () => ({ useAdminGate: () => "allowed" }))

vi.mock("@/components/admin/charts/TimeSeriesLinesChart", () => ({ default: () => <div /> }))
vi.mock("@/components/admin/charts/CohortRetentionChart", () => ({ default: () => <div /> }))
vi.mock("@/components/admin/charts/WeeklyHistogramChart", () => ({ default: () => <div /> }))
vi.mock("@/components/admin/charts/StackedBarsChart", () => ({ default: () => <div /> }))
vi.mock("@/components/admin/charts/CommunitySeriesChart", () => ({ default: () => <div /> }))

vi.mock("@/lib/adminAnalytics", () => ({
  fetchKpiOverview: vi.fn().mockResolvedValue({
    time_series: [],
    insights_breakdown: [],
    community_engagement: [],
    summary: { data_coverage: { operation_events_stale_days: 0 } },
  }),
  fetchRetention: vi.fn().mockResolvedValue([]),
  fetchWeeklyUsageDistribution: vi.fn().mockResolvedValue([]),
  mapKpiHeaderMetrics: () => ({
    umvRate: 0,
    totalActivations: 0,
    avgActiveDaysPerUserWeek: 0,
    totalInsights: 0,
    communityActiveUsers: 0,
  }),
  selectLatestMatureCohort: () => null,
  selectMatureCohorts: () => [],
  buildCohortEmptyMessage: () => "",
  shouldShowDataCoverageWarning: () => false,
}))

const { default: AdminAnalyticsPage } = await import("@/app/(dashboard)/admin/analytics/page")

describe("AdminAnalyticsPage — encabezado de insights (etiqueta «IA»)", () => {
  it("la sección se llama «Distribución de Consejos IA»", async () => {
    render(<AdminAnalyticsPage />)
    expect(
      await screen.findByRole("heading", { level: 2, name: "Distribución de Consejos IA" }),
    ).toBeInTheDocument()
  })
})

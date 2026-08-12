import { describe, it, expect } from "vitest"
import {
  mapKpiHeaderMetrics,
  selectLatestMatureCohort,
  shouldShowDataCoverageWarning,
  DATA_COVERAGE_STALE_THRESHOLD_DAYS,
  type AdminKpiOverview,
  type AdminRetentionCohort,
  type AdminKpiDataCoverage,
} from "@/lib/adminAnalytics"

// ─── Fixtures ─────────────────────────────────────────────────────────────

function makeOverview(overrides: Partial<AdminKpiOverview["summary"]> = {}): AdminKpiOverview {
  return {
    time_series: [],
    insights_breakdown: [],
    community_engagement: [],
    summary: {
      total_activations_in_range: 12,
      total_umv_in_range: 5,
      umv_rate: 42,
      community_active_users: 3,
      total_insights_in_range: 283,
      avg_active_days_per_user_week: 2.4,
      data_coverage: {
        last_operation_created_at: "2026-08-12T00:00:00.000Z",
        last_first_operation_at: "2026-08-01T00:00:00.000Z",
        operation_events_stale_days: 0.5,
      },
      ...overrides,
    },
  }
}

function makeCohort(overrides: Partial<AdminRetentionCohort> = {}): AdminRetentionCohort {
  return {
    cohort_start: "2026-07-01T00:00:00.000Z",
    cohort_size: 10,
    retained_30d: 4,
    retention_rate: 40,
    observation_window_days: 37,
    is_mature: true,
    ...overrides,
  }
}

// ─── mapKpiHeaderMetrics — D1: los KPI de cabecera se leen tal cual de     ──
// summary, sin reduce/suma/promedio del lado del cliente.                  ──

describe("mapKpiHeaderMetrics", () => {
  it("lee cada campo de summary sin recalcularlo", () => {
    const overview = makeOverview()
    expect(mapKpiHeaderMetrics(overview)).toEqual({
      umvRate: 42,
      totalActivations: 12,
      totalUmv: 5,
      communityActiveUsers: 3,
      totalInsights: 283,
      avgActiveDaysPerUserWeek: 2.4,
    })
  })

  it("refleja un segundo overview con valores distintos (no hay estado cacheado)", () => {
    const overview = makeOverview({
      total_activations_in_range: 0,
      total_umv_in_range: 0,
      umv_rate: 0,
      community_active_users: 0,
      total_insights_in_range: 0,
      avg_active_days_per_user_week: 0,
    })
    expect(mapKpiHeaderMetrics(overview)).toEqual({
      umvRate: 0,
      totalActivations: 0,
      totalUmv: 0,
      communityActiveUsers: 0,
      totalInsights: 0,
      avgActiveDaysPerUserWeek: 0,
    })
  })
})

// ─── selectLatestMatureCohort — D4: el panel filtra por is_mature, no por  ──
// aritmética de fechas del cliente.                                        ──

describe("selectLatestMatureCohort", () => {
  it("elige la cohorte madura más reciente cuando hay varias", () => {
    const cohorts: AdminRetentionCohort[] = [
      makeCohort({ cohort_start: "2026-06-01T00:00:00.000Z", is_mature: true, retention_rate: 20 }),
      makeCohort({ cohort_start: "2026-07-01T00:00:00.000Z", is_mature: true, retention_rate: 40 }),
      makeCohort({ cohort_start: "2026-08-01T00:00:00.000Z", is_mature: false, retention_rate: 90 }),
    ]
    const latest = selectLatestMatureCohort(cohorts)
    expect(latest?.cohort_start).toBe("2026-07-01T00:00:00.000Z")
    expect(latest?.retention_rate).toBe(40)
  })

  it("devuelve null cuando ninguna cohorte maduró", () => {
    const cohorts: AdminRetentionCohort[] = [
      makeCohort({ cohort_start: "2026-08-05T00:00:00.000Z", is_mature: false }),
      makeCohort({ cohort_start: "2026-08-10T00:00:00.000Z", is_mature: false }),
    ]
    expect(selectLatestMatureCohort(cohorts)).toBeNull()
  })

  it("devuelve null con lista vacía", () => {
    expect(selectLatestMatureCohort([])).toBeNull()
  })
})

// ─── shouldShowDataCoverageWarning — D3: aviso cuando la telemetría de     ──
// operación está estancada por más del umbral configurado (7 días).        ──

describe("shouldShowDataCoverageWarning", () => {
  it("no muestra aviso cuando la telemetría está al día", () => {
    const coverage: AdminKpiDataCoverage = {
      last_operation_created_at: "2026-08-12T00:00:00.000Z",
      last_first_operation_at: "2026-08-12T00:00:00.000Z",
      operation_events_stale_days: 0,
    }
    expect(shouldShowDataCoverageWarning(coverage)).toBe(false)
  })

  it("muestra aviso cuando la antigüedad supera el umbral", () => {
    const coverage: AdminKpiDataCoverage = {
      last_operation_created_at: "2026-05-28T00:00:00.000Z",
      last_first_operation_at: "2026-05-01T00:00:00.000Z",
      operation_events_stale_days: 76.7,
    }
    expect(shouldShowDataCoverageWarning(coverage)).toBe(true)
  })

  it("el umbral es exclusivo: exactamente en el borde no dispara el aviso", () => {
    const coverage: AdminKpiDataCoverage = {
      last_operation_created_at: "2026-08-05T00:00:00.000Z",
      last_first_operation_at: "2026-08-05T00:00:00.000Z",
      operation_events_stale_days: DATA_COVERAGE_STALE_THRESHOLD_DAYS,
    }
    expect(shouldShowDataCoverageWarning(coverage)).toBe(false)
  })

  it("sin ningún evento de operación jamás (stale_days null) no dispara el aviso de estancamiento", () => {
    const coverage: AdminKpiDataCoverage = {
      last_operation_created_at: null,
      last_first_operation_at: null,
      operation_events_stale_days: null,
    }
    expect(shouldShowDataCoverageWarning(coverage)).toBe(false)
  })

  it("acepta un umbral custom", () => {
    const coverage: AdminKpiDataCoverage = {
      last_operation_created_at: "2026-08-10T00:00:00.000Z",
      last_first_operation_at: "2026-08-10T00:00:00.000Z",
      operation_events_stale_days: 3,
    }
    expect(shouldShowDataCoverageWarning(coverage, 2)).toBe(true)
    expect(shouldShowDataCoverageWarning(coverage, 5)).toBe(false)
  })
})

/**
 * Shared types and helpers for the enterprise pagination system.
 *
 * Architecture:
 *   usePaginatedQuery (hook) — fetches one page from Supabase via .range()
 *     ↓
 *   PaginationBar (component) — renders first/prev/page/next/last + page-size selector
 *     ↓
 *   Module page — composes hook + list component + pagination bar
 *
 * Strategy: LIMIT / OFFSET via Supabase .range(from, to).
 *   Appropriate for ERP datasets that are bounded per tenant (< 500k rows).
 *   Supports jumping to arbitrary pages, which users expect in an admin table.
 *
 * Multi-tenant safety:
 *   RLS guarantees user isolation at the DB level. Pagination never needs to
 *   pass user_id — the Supabase client uses the authenticated session automatically.
 */

export const PAGE_SIZE_OPTIONS = [10, 25, 50, 100] as const
export type  PageSizeOption    = typeof PAGE_SIZE_OPTIONS[number]
export type  SortDir           = "asc" | "desc"

// ─── Filter params passed to every applyFilters callback ─────────────────────

export interface FilterParams {
  search:   string
  dateFrom: string
  dateTo:   string
  sortKey:  string | null
  sortDir:  SortDir
}

// ─── Pagination metadata returned by the hook ─────────────────────────────────

export interface PaginationMeta {
  page:       number          // 0-indexed current page
  pageSize:   PageSizeOption
  totalCount: number          // total rows matching the current filters
  pageCount:  number          // total pages
  from:       number          // 1-indexed first row on this page (display use)
  to:         number          // 1-indexed last row on this page (display use)
}

// ─── Supabase query filter callback ──────────────────────────────────────────
// Receives a query builder that already has .from(table).select() applied
// and should return the same builder with .eq / .gte / .ilike chains added.

export type ApplyFilters = (query: any, params: FilterParams) => any

// ─── Helpers ─────────────────────────────────────────────────────────────────

export function buildPaginationMeta(
  page:       number,
  pageSize:   PageSizeOption,
  totalCount: number,
): PaginationMeta {
  const pageCount = Math.max(1, Math.ceil(totalCount / pageSize))
  const safePage  = Math.min(Math.max(0, page), pageCount - 1)
  return {
    page:       safePage,
    pageSize,
    totalCount,
    pageCount,
    from: totalCount === 0 ? 0 : safePage * pageSize + 1,
    to:   Math.min((safePage + 1) * pageSize, totalCount),
  }
}

/** ISO date string for N days ago (YYYY-MM-DD). */
export function daysAgo(n: number): string {
  const d = new Date()
  d.setDate(d.getDate() - n)
  return d.toISOString().split("T")[0]
}

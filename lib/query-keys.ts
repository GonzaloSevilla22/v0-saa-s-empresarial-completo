/**
 * Centralized query key factory.
 *
 * Rules:
 * - Every key starts with the domain name so prefix invalidation works.
 * - invalidateQueries({ queryKey: queryKeys.courses.all() })
 *   will invalidate ALL courses queries (list, detail, summary, etc.)
 * - Keys are const tuples for type safety.
 */
export const queryKeys = {
  courses: {
    all:    () => ["courses"] as const,
    lists:  () => ["courses", "list"] as const,
    detail: (id: string) => ["courses", "detail", id] as const,
  },
  expenses: {
    all:     () => ["expenses"] as const,
    lists:   () => ["expenses", "list"] as const,
    summary: () => ["expenses", "summary"] as const,
  },
  products: {
    all:    () => ["products"] as const,
    lists:  () => ["products", "list"] as const,
    detail: (id: string) => ["products", "detail", id] as const,
  },
  sales: {
    all:     () => ["sales"] as const,
    lists:   () => ["sales", "list"] as const,
    summary: () => ["sales", "summary"] as const,
  },
  purchases: {
    all:   () => ["purchases"] as const,
    lists: () => ["purchases", "list"] as const,
  },
  clients: {
    all:     () => ["clients"] as const,
    lists:   () => ["clients", "list"] as const,
    metrics: () => ["clients", "metrics"] as const,
  },
  insights: {
    all: () => ["insights"] as const,
  },
  posts: {
    all:    () => ["posts"] as const,
    detail: (id: string) => ["posts", "detail", id] as const,
  },
} as const

/**
 * Pure "meta alcanzada" milestone detector (task 3.6). Purely presentational:
 * takes a previous/current numeric reading of a KPI the caller already
 * fetched through its existing (untouched) data flow, and a list of
 * round-number thresholds — returns the highest one newly crossed, or
 * `null`. Does not fetch, own, or mutate any KPI itself.
 *
 * Consumed by `hooks/three/useGoalMilestone.ts`, which adds the "first real
 * reading establishes a baseline, never itself a celebration" policy (see
 * that hook's docstring for why).
 */
export function findCrossedMilestone(
  previous: number,
  current: number,
  thresholds: readonly number[],
): number | null {
  const crossed = thresholds.filter((threshold) => previous < threshold && current >= threshold)
  if (crossed.length === 0) return null
  return Math.max(...crossed)
}

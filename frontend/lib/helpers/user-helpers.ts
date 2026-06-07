/**
 * user-helpers.ts
 * Pure helper functions for user display and personalization.
 * No React deps, no Supabase deps — fully testable in isolation.
 */

// ─── capitalizeName ───────────────────────────────────────────────────────────
/**
 * Capitalizes the first letter of each word and lowercases the rest.
 *
 * @example
 *   capitalizeName("gonzalo")         // "Gonzalo"
 *   capitalizeName("MARIA")           // "Maria"
 *   capitalizeName("gonzalo sevilla") // "Gonzalo Sevilla"
 */
export function capitalizeName(name: string): string {
  if (!name) return ""
  return name
    .trim()
    .toLowerCase()
    .replace(/\b[a-zà-ü]/g, (c) => c.toUpperCase())
}

// ─── getFirstName ─────────────────────────────────────────────────────────────
/**
 * Extracts the first word of a full name, capitalizes it and returns it.
 * Returns the fallback when the name is null, undefined, or empty.
 *
 * @example
 *   getFirstName("Gonzalo Sevilla")  // "Gonzalo"
 *   getFirstName("MARIA jose")       // "Maria"
 *   getFirstName("gonzalo.sevilla")  // "Gonzalo"
 *   getFirstName(null)               // "Emprendedor"
 */
export function getFirstName(
  fullName: string | null | undefined,
  fallback = "Emprendedor"
): string {
  const cleaned = (fullName ?? "").trim().replace(/[._-]+/g, " ")
  if (!cleaned) return fallback
  const first = cleaned.split(/\s+/)[0]
  return capitalizeName(first) || fallback
}

// ─── getGreetingPeriod ────────────────────────────────────────────────────────
/**
 * Returns only the time-period greeting without a name.
 * Useful for rendering period and name in separate styled spans.
 *
 * @example
 *   getGreetingPeriod(new Date(...at 9am...))   // "Buen dia"
 *   getGreetingPeriod(new Date(...at 3pm...))   // "Buenas tardes"
 *   getGreetingPeriod(new Date(...at 10pm...))  // "Buenas noches"
 */
export function getGreetingPeriod(date: Date = new Date()): string {
  const h = date.getHours()
  if (h < 12) return "Buen dia"
  if (h < 20) return "Buenas tardes"
  return "Buenas noches"
}

// ─── getGreeting ──────────────────────────────────────────────────────────────
/**
 * Time-aware greeting in Spanish, combined with the user first name.
 *
 * Time ranges (local browser time):
 *   00:00 - 11:59  ->  "Buen dia"
 *   12:00 - 19:59  ->  "Buenas tardes"
 *   20:00 - 23:59  ->  "Buenas noches"
 *
 * @param name     Full name or first name (accepts null/undefined).
 * @param fallback Shown when name is empty. Default: "Emprendedor".
 * @param date     Injectable for testing. Default: current time.
 *
 * @example
 *   getGreeting("Gonzalo Sevilla")  // "Buen dia, Gonzalo"
 *   getGreeting("MARIA")           // "Buenas tardes, Maria"
 *   getGreeting(null)              // "Buen dia, Emprendedor"
 */
export function getGreeting(
  name?: string | null,
  fallback = "Emprendedor",
  date: Date = new Date()
): string {
  const period = getGreetingPeriod(date)
  const displayName = getFirstName(name, fallback)
  return `${period}, ${displayName}`
}

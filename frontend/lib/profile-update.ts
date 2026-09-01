/**
 * qa-integral-modulos G11 (H9) — payload del update de perfil.
 *
 * El contrato que faltaba: distinguir "campo NO enviado" (undefined → la
 * columna no se toca) de "campo enviado vacío" (null → la columna se limpia).
 * Antes `updateProfile` hacía `?? undefined`, que colapsaba ambos y volvía
 * imposible vaciar un campo desde la UI (los 5 opcionales del perfil).
 * Es el equivalente frontend del `model_fields_set` que el backend ya usa.
 */

export interface ProfileUpdateData {
  name?: string
  lastName?: string | null
  businessName?: string | null
  phone?: string | null
  locality?: string | null
  bio?: string | null
  avatarUrl?: string | null
}

const COLUMN_BY_FIELD = {
  name: "name",
  lastName: "last_name",
  businessName: "business_name",
  phone: "phone",
  locality: "locality",
  bio: "bio",
  avatarUrl: "avatar_url",
} as const satisfies Record<keyof ProfileUpdateData, string>

/**
 * Mapea a columnas snake_case incluyendo SOLO los campos presentes:
 * undefined se omite (columna intacta); null pasa como null (columna a NULL).
 */
export function buildProfileUpdatePayload(
  data: ProfileUpdateData,
): Record<string, string | null> {
  const payload: Record<string, string | null> = {}
  for (const [field, column] of Object.entries(COLUMN_BY_FIELD) as [
    keyof ProfileUpdateData,
    string,
  ][]) {
    const value = data[field]
    if (value !== undefined) payload[column] = value
  }
  return payload
}

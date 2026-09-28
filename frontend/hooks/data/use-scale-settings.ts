"use client"

/**
 * balanza-etiquetas-pos (D3/D10/D13) — `useScaleSettings` / `useUpdateScaleSettings`.
 *
 * El contrato de transporte es el objeto `ScaleSettings` TAL CUAL (D3: la
 * columna `layouts` es un único JSONB que la API pasa sin traducir; no hay
 * snake_case que mapear acá, a diferencia del resto de los hooks de este
 * archivo — el mismo fixture compartido con pytest, `scale_layout_cases.json`,
 * documenta `PUT /scale-settings` recibiendo exactamente esta forma).
 */

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import { FACTORY_SCALE_SETTINGS, scaleSettingsSchema, type ScaleSettings } from "@/lib/scale-layout"

function parseScaleSettings(raw: unknown): ScaleSettings {
  const parsed = scaleSettingsSchema.safeParse(raw)
  // D10: "respuesta inválida → FACTORY deshabilitada sin romper" — cubre una
  // base sin la migración, una fila corrupta o un backend viejo.
  return parsed.success ? (parsed.data as ScaleSettings) : FACTORY_SCALE_SETTINGS
}

/**
 * Lee la configuración de balanza de la cuenta activa. `staleTime` corto con
 * `refetchOnWindowFocus`/`refetchOnMount` ACTIVOS (a diferencia del default
 * global de la app, `refetchOnWindowFocus: false`): el POS queda abierto
 * todo el día, y si el owner cambia los decimales desde otra PC, un POS con
 * la configuración en caché decodificaría con la vieja — D10, riesgo de
 * cobrar 100 veces menos.
 */
export function useScaleSettings() {
  const query = useQuery({
    queryKey: queryKeys.scaleSettings.detail(),
    queryFn: async (): Promise<ScaleSettings> => {
      const data = await pythonClient.get<unknown>("/scale-settings")
      return parseScaleSettings(data)
    },
    staleTime: 30 * 1000,
    refetchOnWindowFocus: true,
    refetchOnMount: true,
  })

  return {
    settings:  query.data ?? FACTORY_SCALE_SETTINGS,
    isLoading: query.isLoading,
    isError:   query.isError,
    error:     query.error,
  }
}

/** Guarda la configuración de balanza (D3: sólo owner/admin — 403 si no). */
export function useUpdateScaleSettings() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (settings: ScaleSettings): Promise<ScaleSettings> => {
      const data = await pythonClient.put<unknown>("/scale-settings", settings)
      return parseScaleSettings(data)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.scaleSettings.all() })
    },
  })
}

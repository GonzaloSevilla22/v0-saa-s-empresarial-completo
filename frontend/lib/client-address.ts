/**
 * remitos-venta (D11) — el domicilio de entrega que el remito precarga.
 *
 * Las direcciones operativas del cliente (`client_addresses`, v3-catalog-masters)
 * son distintas de la dirección FISCAL: el remito imprime la de entrega. Se
 * precarga con la PRINCIPAL del cliente y el usuario la edita.
 */
import type { ClientAddress } from "@/lib/types"

/**
 * `San Martín 100, Mendoza, Mendoza (5500)`: calle, localidad, provincia y el
 * código postal entre paréntesis; lo que falta se omite sin dejar comas
 * sueltas. El alias y las notas no son parte del domicilio impreso.
 */
export function formatClientAddress(
  address: Pick<ClientAddress, "street" | "city" | "province" | "postalCode">,
): string {
  const parts = [address.street, address.city, address.province]
    .map((part) => part?.trim())
    .filter((part): part is string => !!part)
  const postalCode = address.postalCode?.trim()
  if (postalCode) parts.push(`(${postalCode})`)
  // El código postal va pegado al último dato, no separado por coma.
  if (postalCode && parts.length > 1) {
    const code = parts.pop() as string
    parts[parts.length - 1] = `${parts[parts.length - 1]} ${code}`
  }
  return parts.join(", ")
}

/**
 * El domicilio con el que se precarga el remito: el principal del cliente. Si
 * el principal no tiene datos (o ninguno está marcado), el primero que sí los
 * tenga — nunca precarga vacío habiendo algo. Sin direcciones: texto vacío.
 */
export function primaryDeliveryAddress(addresses: readonly ClientAddress[] | undefined): string {
  if (!addresses || addresses.length === 0) return ""
  const ordered = [...addresses.filter((a) => a.isPrimary), ...addresses.filter((a) => !a.isPrimary)]
  for (const address of ordered) {
    const text = formatClientAddress(address)
    if (text) return text
  }
  return ""
}

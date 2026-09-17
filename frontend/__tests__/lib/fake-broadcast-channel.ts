/**
 * Doble de `BroadcastChannel` para los tests del transporte entre pestañas.
 *
 * Simula varias "pestañas" con instancias del mismo nombre de canal, entregando
 * cada mensaje **sólo a las otras** instancias — igual que el `BroadcastChannel`
 * real, que nunca le devuelve el mensaje al emisor. La entrega es **síncrona**
 * (el de jsdom no lo es), que es lo que permite asertar sin esperas.
 *
 * Vive acá, y no dentro de un archivo de test, porque desde el grupo 20 de
 * `auth-hardening-jwt-cookies` lo consumen dos suites: la del transporte
 * (`__tests__/idle-transport.test.ts`) y la del bus de eventos de sesión
 * (`__tests__/lib/session-bus.test.ts`). Dos dobles distintos del mismo canal
 * compartido divergen, y el día que divergen dejan de probar lo mismo.
 */

type MessageHandler = (ev: { data: unknown }) => void

export class FakeBroadcastChannel {
  static instances: FakeBroadcastChannel[] = []

  static reset(): void {
    FakeBroadcastChannel.instances = []
  }

  private listeners: MessageHandler[] = []

  constructor(public name: string) {
    FakeBroadcastChannel.instances.push(this)
  }

  addEventListener(_: "message", handler: MessageHandler): void {
    this.listeners.push(handler)
  }

  postMessage(data: unknown): void {
    // Deliver to all OTHER instances with the same channel name
    for (const inst of FakeBroadcastChannel.instances) {
      if (inst !== this && inst.name === this.name) {
        for (const h of inst.listeners) h({ data })
      }
    }
  }

  close(): void {
    const idx = FakeBroadcastChannel.instances.indexOf(this)
    if (idx !== -1) FakeBroadcastChannel.instances.splice(idx, 1)
  }
}

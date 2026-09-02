"use client"

import { use } from "react"
import { CreditCard } from "lucide-react"
import { Button } from "@/components/ui/button"
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import { useState } from "react"
import { useCustomerAccount } from "@/hooks/data/use-customer-account"
import { CustomerAccountBalance } from "@/components/customer-accounts/CustomerAccountBalance"
import { CustomerAccountHistory } from "@/components/customer-accounts/CustomerAccountHistory"
import { RegisterPaymentForm } from "@/components/customer-accounts/RegisterPaymentForm"

interface PageProps {
  params: Promise<{ id: string }>
}

export default function ClienteAccountPage({ params }: PageProps) {
  const { id: clientId } = use(params)
  const [paymentOpen, setPaymentOpen] = useState(false)

  const { data: account, isLoading, error, refetch } = useCustomerAccount(clientId)

  return (
    <div className="flex flex-col gap-6">
      {/* clientes-frecuentes-historial: la cabecera ("Cuenta corriente" +
          botón de volver) la absorbe el layout compartido de
          /clientes/[id]/layout.tsx — acá sólo queda la acción propia de esta
          pestaña. */}
      <div className="flex justify-end">
        <Button size="sm" onClick={() => setPaymentOpen(true)}>
          <CreditCard className="h-4 w-4 mr-2" />
          Registrar cobro
        </Button>
      </div>

      {/* Error state */}
      {error && (
        <div className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
          {(error as Error).message || "Error al cargar la cuenta corriente"}
        </div>
      )}

      {/* Balance card */}
      <CustomerAccountBalance
        balance={account?.balance ?? 0}
      />

      {/* Movements history */}
      <CustomerAccountHistory
        movements={account?.movements ?? []}
        loading={isLoading}
        clientId={clientId}
      />

      {/* Register payment dialog */}
      <Dialog open={paymentOpen} onOpenChange={setPaymentOpen}>
        <DialogContent className="bg-card border-border sm:max-w-md">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">
              Registrar cobro
            </DialogTitle>
          </DialogHeader>
          <RegisterPaymentForm
            clientId={clientId}
            onSuccess={() => {
              setPaymentOpen(false)
              refetch()
            }}
          />
        </DialogContent>
      </Dialog>
    </div>
  )
}

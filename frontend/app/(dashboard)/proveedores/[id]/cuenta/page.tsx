"use client"

import { use, useState } from "react"
import Link from "next/link"
import { ArrowLeft, Banknote } from "lucide-react"
import { Button } from "@/components/ui/button"
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import { useSupplierAccount } from "@/hooks/data/use-supplier-account"
import { SupplierAccountBalance } from "@/components/supplier-accounts/SupplierAccountBalance"
import { SupplierAccountHistory } from "@/components/supplier-accounts/SupplierAccountHistory"
import { RegisterPaymentMadeForm } from "@/components/supplier-accounts/RegisterPaymentMadeForm"

interface PageProps {
  params: Promise<{ id: string }>
}

export default function ProveedorAccountPage({ params }: PageProps) {
  const { id: supplierId } = use(params)
  const [paymentOpen, setPaymentOpen] = useState(false)

  const { data: account, isLoading, error, refetch } = useSupplierAccount(supplierId)

  return (
    <div className="flex flex-col gap-6">
      {/* Header */}
      <div className="flex items-center gap-3">
        <Button variant="ghost" size="icon" asChild className="h-8 w-8 shrink-0">
          <Link href="/compras">
            <ArrowLeft className="h-4 w-4" />
          </Link>
        </Button>
        <div className="flex-1 min-w-0">
          <h1 className="text-2xl font-bold text-foreground tracking-tight">
            Cuenta corriente
          </h1>
          <p className="text-sm text-muted-foreground mt-0.5">
            Saldo y movimientos del proveedor
          </p>
        </div>
        <Button size="sm" onClick={() => setPaymentOpen(true)}>
          <Banknote className="h-4 w-4 mr-2" />
          Registrar pago
        </Button>
      </div>

      {/* Error state */}
      {error && (
        <div className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
          {(error as Error).message || "Error al cargar la cuenta corriente"}
        </div>
      )}

      {/* Balance card */}
      <SupplierAccountBalance balance={account?.balance ?? 0} />

      {/* Movements history */}
      <SupplierAccountHistory
        movements={account?.movements ?? []}
        loading={isLoading}
      />

      {/* Register payment dialog */}
      <Dialog open={paymentOpen} onOpenChange={setPaymentOpen}>
        <DialogContent className="bg-card border-border sm:max-w-md">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">
              Registrar pago al proveedor
            </DialogTitle>
          </DialogHeader>
          <RegisterPaymentMadeForm
            supplierId={supplierId}
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

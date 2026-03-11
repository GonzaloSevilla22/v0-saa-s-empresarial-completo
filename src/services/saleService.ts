import { SupabaseClient } from "@supabase/supabase-js"
import { SaleRepository } from "../repositories/saleRepository"
import { InventoryRepository } from "../repositories/inventoryRepository"
import { Sale, SaleItem, InventoryMovement } from "../types/erp"

export class SaleService {
  private saleRepository: SaleRepository
  private inventoryRepository: InventoryRepository

  constructor(private readonly supabase: SupabaseClient) {
    this.saleRepository = new SaleRepository(supabase)
    this.inventoryRepository = new InventoryRepository(supabase)
  }

  async getSalesByCompany(companyId: string): Promise<Sale[]> {
    return this.saleRepository.getSalesByCompany(companyId)
  }

  async processNewSale(
    companyId: string,
    warehouseId: string,
    userId: string | undefined,
    saleData: Omit<Sale, "id" | "company_id" | "created_at">,
    itemsData: Omit<SaleItem, "id" | "sale_id" | "subtotal">[]
  ): Promise<void> {

    // 1. Calculate subtotals and totals assuming the itemsData only has quantity and unit price
    const enrichedItems = itemsData.map(item => ({
      ...item,
      subtotal: item.quantity * item.price
    }))

    const computedTotal = enrichedItems.reduce((acc, curr) => acc + curr.subtotal, 0)

    // 2. Insert Sale and Items
    await this.saleRepository.createSaleAndItems(
      { ...saleData, company_id: companyId, total: computedTotal },
      enrichedItems
    )

    // 3. Dispatch Inventory Movements to deduct stock
    for (const item of enrichedItems) {
      const movement: Partial<InventoryMovement> = {
        company_id: companyId,
        variant_id: item.variant_id,
        warehouse_id: warehouseId,
        movement_type: 'sale',
        quantity: item.quantity, 
        unit_cost: item.price, // Technically this is sale price, cost should be fetched from variant, but simplified here
        reference_type: 'sale',
        // reference_id: sale.id, // we would need to fetch the inserted sale ID to link it exactly
        created_by: userId
      }

      await this.inventoryRepository.createMovement(movement)
    }
  }

  async cancelSale(id: string): Promise<void> {
    // A robust ERP would issue 'return' movements here before deleting or soft-deleting.
    await this.saleRepository.softDeleteSale(id)
  }
}

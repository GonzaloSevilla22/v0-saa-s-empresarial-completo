import { SupabaseClient } from "@supabase/supabase-js"
import { ProductRepository } from "../repositories/productRepository"
import { InventoryRepository } from "../repositories/inventoryRepository"
import { Product, ProductVariant, InventoryMovement } from "../types/erp"

export class ProductService {
  private productRepository: ProductRepository
  private inventoryRepository: InventoryRepository

  constructor(private readonly supabase: SupabaseClient) {
    this.productRepository = new ProductRepository(supabase)
    this.inventoryRepository = new InventoryRepository(supabase)
  }

  async getProductsByCompany(companyId: string): Promise<Product[]> {
    return this.productRepository.getProductsByCompany(companyId)
  }

  async createProductWithInitialStock(
    companyId: string,
    warehouseId: string,
    userId: string | undefined,
    productData: Omit<Product, 'id' | 'company_id' | 'created_at' | 'deleted_at' | 'variants'>,
    variantData: Omit<ProductVariant, 'id' | 'product_id' | 'created_at' | 'stock'>,
    initialStock: number
  ): Promise<Product> {
    
    // 1. Create Product and Variant
    const newProduct = await this.productRepository.createProductAndVariant(
      { ...productData, company_id: companyId },
      variantData
    )

    const variantId = newProduct.variants?.[0]?.id

    // 2. Insert initial stock adjustment if stock > 0
    if (variantId && initialStock > 0) {
      const movement: Partial<InventoryMovement> = {
        company_id: companyId,
        variant_id: variantId,
        warehouse_id: warehouseId,
        movement_type: 'adjustment',
        quantity: initialStock,
        unit_cost: variantData.cost,
        reference_type: 'initial_stock',
        created_by: userId
      }

      await this.inventoryRepository.createMovement(movement)
    }

    // Return decorated product
    return {
      ...newProduct,
      variants: newProduct.variants?.map(v => ({ ...v, stock: initialStock }))
    }
  }

  async updateProduct(id: string, updates: Partial<Product>): Promise<void> {
    await this.productRepository.updateProduct(id, updates)
  }

  async updateVariant(id: string, updates: Partial<ProductVariant>): Promise<void> {
    await this.productRepository.updateVariant(id, updates)
  }

  async deleteProduct(id: string): Promise<void> {
    // We enforce soft-deletes to keep history of sales intact
    await this.productRepository.softDeleteProduct(id)
  }
}

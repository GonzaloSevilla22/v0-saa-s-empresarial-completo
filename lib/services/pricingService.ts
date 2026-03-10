export const pricingService = {
  /**
   * Calculates the margin percentage based on cost and price.
   * Formula: ((price - cost) / price) * 100
   */
  calculateMargin(cost: number, price: number): number {
    if (price <= 0) return 0
    return ((price - cost) / price) * 100
  },

  /**
   * Suggests a price for a target margin.
   * Formula: price = cost / (1 - margin / 100)
   */
  suggestPrice(cost: number, targetMargin: number): number {
    if (targetMargin >= 100) return cost * 10 // Safety fallback
    const price = cost / (1 - targetMargin / 100)
    return Math.round(price)
  },

  /**
   * Returns a range of suggested prices for common margins.
   */
  suggestPriceRange(cost: number) {
    return {
      margins: [
        { percentage: 30, price: this.suggestPrice(cost, 30) },
        { percentage: 40, price: this.suggestPrice(cost, 40) },
        { percentage: 50, price: this.suggestPrice(cost, 50) }
      ],
      recommendation: "En ferias y venta directa, se suele recomendar un margen entre el 40% y 50% para cubrir gastos operativos y obtener ganancia real."
    }
  }
}

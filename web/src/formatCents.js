// Format cents with 2 decimals, rounding halves up without floating point noise
// (e.g. 15.335 -> "15.34"). TRMNL plugin uses the same rounding.
export function formatCents (value) {
  return (Math.round(Math.round(value * 1e6) / 1e4) / 100).toFixed(2)
}

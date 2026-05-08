import Foundation

/// Errors thrown by `PriceService`.
enum PriceServiceError: Error, Sendable {
    case invalidURL
    case invalidResponse
}

/// Networking-only client for the public price JSON files served from S3.
/// Stateless — one instance per call site is fine.
struct PriceService: Sendable {
    static let baseURL = "https://borsihind.s3.eu-central-1.amazonaws.com"

    /// Fetches the entire price file. Filtering by current time is the
    /// view-model's job so the visible window can advance every minute
    /// without re-hitting the network.
    func fetchPrices(plan: Plan, interval: Interval) async throws -> [PriceEntry] {
        let path = interval == .oneHour ? "\(plan.rawValue).json" : "15min/\(plan.rawValue).json"
        guard let url = URL(string: "\(Self.baseURL)/\(path)") else {
            throw PriceServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PriceServiceError.invalidResponse
        }

        let raw = try JSONDecoder().decode([[Double]].self, from: data)
        return raw.compactMap { PriceEntry.decode(from: $0) }
    }
}

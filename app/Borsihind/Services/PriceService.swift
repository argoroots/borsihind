import Foundation

/// Errors thrown by `PriceService`.
enum PriceServiceError: Error, Sendable {
    case invalidURL
    case invalidResponse
}

/// Stateless networking client for the public S3 price files.
struct PriceService: Sendable {
    static let baseURL = "https://borsihind.s3.eu-central-1.amazonaws.com"

    /// Fetch the entire price file. The viewmodel filters by current time
    /// so the visible window can advance every minute without re-hitting
    /// the network.
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

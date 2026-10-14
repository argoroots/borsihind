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
        guard let url = URL(string: "\(Self.baseURL)/v2/\(interval.rawValue)/\(plan.rawValue).json") else {
            throw PriceServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PriceServiceError.invalidResponse
        }

        // Slot times are ISO 8601 UTC, e.g. 2026-10-14T06:30:00Z
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(PriceFile.self, from: data)
        return file.prices.map(PriceEntry.init(slot:))
    }
}

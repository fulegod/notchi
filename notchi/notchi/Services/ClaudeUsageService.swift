import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "ClaudeUsageService")

@MainActor @Observable
final class ClaudeUsageService {
    static let shared = ClaudeUsageService()

    var currentUsage: QuotaPeriod?
    var isLoading = false
    var error: String?
    var isConnected = false

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private static let authFailureStatusCodes: Set<Int> = [401, 403]

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 120
    private var cachedToken: String?
    private var consecutive429Count = 0

    private init() {}

    func connectAndStartPolling() {
        AppSettings.isUsageEnabled = true
        error = nil
        stopPolling()

        Task {
            // Try cached token first to avoid keychain password prompt
            var accessToken = cachedToken ?? KeychainManager.getCachedOAuthToken()
            if accessToken == nil {
                // Only prompt for keychain access if no cached token
                accessToken = KeychainManager.getAccessToken()
            }
            guard let accessToken else {
                error = "Se requiere acceso al llavero"
                isConnected = false
                AppSettings.isUsageEnabled = false
                return
            }
            await fetchAndStartPolling(with: accessToken)
        }
    }

    func startPolling() {
        stopPolling()

        guard AppSettings.isUsageEnabled else {
            logger.info("Usage polling disabled by user")
            return
        }

        Task {
            // Try cached token first, then try reading from Claude Code keychain
            var accessToken = KeychainManager.getCachedOAuthToken()
            if accessToken == nil {
                accessToken = KeychainManager.getAccessToken()
            }
            guard let accessToken else {
                logger.info("No token available, user must connect manually")
                isConnected = false
                return
            }
            await fetchAndStartPolling(with: accessToken)
        }
    }

    func retryNow() {
        error = nil
        stopPolling()
        Task {
            guard let accessToken = cachedToken else {
                connectAndStartPolling()
                return
            }
            await performFetch(with: accessToken)
            schedulePollTimer()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func fetchAndStartPolling(with accessToken: String) async {
        cachedToken = accessToken
        // Validate token with profile endpoint first (more reliable than usage)
        if !isConnected {
            await validateConnection(with: accessToken)
        }
        await performFetch(with: accessToken)
        schedulePollTimer()
    }

    private func validateConnection(with accessToken: String) async {
        var request = URLRequest(url: Self.profileURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                isConnected = true
                logger.info("Connection validated via profile endpoint")
            }
        } catch {
            logger.warning("Profile validation failed: \(error.localizedDescription)")
        }
    }

    private func schedulePollTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchUsage()
            }
        }
        logger.info("Started usage polling (every \(self.pollInterval)s)")
    }

    private func fetchUsage() async {
        guard let accessToken = cachedToken else {
            logger.warning("No cached token available, stopping polling")
            stopPolling()
            return
        }

        await performFetch(with: accessToken)
    }

    private func performFetch(with accessToken: String) async {
        isLoading = true

        defer { isLoading = false }

        var request = URLRequest(url: Self.usageURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Notchi", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                error = "Respuesta inválida"
                return
            }

            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 429 {
                    isConnected = true
                    consecutive429Count += 1

                    // Try reading a fresher token from Claude Code's keychain
                    if consecutive429Count <= 2,
                       let freshToken = KeychainManager.refreshAccessTokenSilently(),
                       freshToken != accessToken {
                        logger.info("Found newer token from Claude Code keychain")
                        cachedToken = freshToken
                        consecutive429Count = 0
                        await performFetch(with: freshToken)
                    } else if currentUsage == nil {
                        error = "Uso no disponible temporalmente"
                    } else {
                        error = nil
                    }
                    return
                }

                if Self.authFailureStatusCodes.contains(httpResponse.statusCode) {
                    // Try reading fresh token from Claude Code keychain
                    if let freshToken = KeychainManager.refreshAccessTokenSilently(),
                       freshToken != accessToken {
                        logger.info("Token refreshed from Claude Code keychain")
                        await fetchAndStartPolling(with: freshToken)
                        return
                    }

                    cachedToken = nil
                    KeychainManager.clearCachedOAuthToken()
                    error = "Token expirado"
                    isConnected = false
                    stopPolling()
                } else {
                    error = "HTTP \(httpResponse.statusCode)"
                }
                logger.warning("API error: HTTP \(httpResponse.statusCode)")
                return
            }

            let usageResponse = try JSONDecoder().decode(UsageResponse.self, from: data)
            isConnected = true
            error = nil
            consecutive429Count = 0
            currentUsage = usageResponse.fiveHour
            logger.info("Usage fetched: \(self.currentUsage?.usagePercentage ?? 0)%")

        } catch {
            self.error = "Error de red"
            logger.error("Fetch failed: \(error.localizedDescription)")
        }
    }
}

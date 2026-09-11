// JamfService.swift
// Jamf Pro API actor — all methods are actor-isolated; token state is safe under concurrency.
//
// Auth:  POST {jamfURL}/api/v1/oauth/token  (client_credentials, OAuth2)
//        TTL = 59s from server. Token passed explicitly to concurrent PATCH tasks
//        to avoid 8× redundant fetchToken() calls.
//
// Computers: GET /api/v4/computers-inventory  (paginated, serialNumber in hardware{})
// Mobile:    GET /api/v2/mobile-devices/detail (paginated, serialNumber in hardware{})
// PATCH computer: PATCH /api/v4/computers-inventory-detail/{id}  body: {purchasing:{…}}
// PATCH mobile:   PATCH /api/v2/mobile-devices/{id}              body: {ios:{purchasing:{…}}}
//
// v3→v4 migration note (Jamf Pro 11.30): the `general` object renamed lastContactTime
// to lastCheckIn (we've switched to it below — it's Jamf's more complete check-in
// signal, covering binary/MDM/DDM contact rather than just one method) and removed
// lastReportedIp (we never used it). All other general fields are unchanged, and the
// `section` query parameter and pagination/sort/filter mechanics are identical to v3.

import Foundation

// MARK: - Jamf API response types

private struct JamfTokenResponse: Decodable {
    let access_token: String
    let expires_in:   Int
}

/// Top-level paginated response from /api/v4/computers-inventory
private struct JamfInventoryResponse: Decodable {
    let totalCount: Int
    let results:    [JamfInventoryRecord]
}

/// One computer record — sections mirror the ?section= query params
private struct JamfInventoryRecord: Decodable {
    let id:              String
    let udid:            String?   // top-level, NOT inside general{} — confirmed from API response
    let general:         JamfGeneral?
    let hardware:        JamfHardware?
    let operatingSystem: JamfOperatingSystem?
    let purchasing:      JamfPurchasing?
    let userAndLocation: JamfUserAndLocation?
    let diskEncryption:  JamfDiskEncryption?
}

private struct JamfOperatingSystem: Decodable {
    let name:                    String?   // "macOS"
    let version:                 String?   // "14.5"
    let build:                   String?   // "23F79"
    let supplementalBuildVersion: String?
    let rapidSecurityResponse:   String?
    let activeDirectoryStatus:   String?
    let fileVault2Status:        String?   // "ALL_ENCRYPTED" | "BOOT_ENCRYPTED" | "NOT_ENCRYPTED" | "UNKNOWN" — both ALL_ and BOOT_ENCRYPTED count as Encrypted, see AppStore.fileVaultLabel(for:)
    let softwareUpdateDeviceId:  String?
}

private struct JamfGeneral: Decodable {
    let name:              String?
    let reportDate:        String?
    let lastCheckIn:       String?   // renamed from lastContactTime in v4 — Jamf's fuller check-in signal (binary/MDM/DDM)
    let lastEnrolledDate:  String?
    let mdmProfileExpiration: String?   // date-time. NOT "mdmCertificateExpiration" — that name
    // appears in some Jamf docs/schemas, but a live v4 payload confirmed the actual JSON key is
    // "mdmProfileExpiration". Decoding the wrong key silently produced nil forever (Optional
    // properties don't throw on a missing key) — this was the real root cause of the field
    // appearing "missing", not a date-format parsing issue as originally suspected.
    let initialEntryDate:  String?   // plain date "YYYY-MM-DD" — date device was first added to Jamf
    let managementId:      String?
    let remoteManagement:  JamfRemoteManagement?
    let udid:              String?
    let platform:          String?       // "Mac"
    let supervised:        Bool?
    let mdmCapable:        JamfMdmCapable?
    let enrolledViaAutomatedDeviceEnrollment: Bool?
    let itunesStoreAccountActive:             Bool?
}

private struct JamfRemoteManagement: Decodable {
    let managed:               Bool?
    let managementUsername:    String?
}

private struct JamfMdmCapable: Decodable {
    let capable:        Bool?
    let capableUsers:   [String]?
}

private struct JamfHardware: Decodable {
    let serialNumber:            String?
    let model:                   String?
    let modelIdentifier:         String?
    let macAddress:              String?
    let altMacAddress:           String?
    let processorType:           String?
    let processorArchitecture:   String?
    let processorSpeedMhz:       Int?
    let numberOfCores:           Int?
    let totalRamMegabytes:       Int?
    let batteryCapacityPercent:  Int?
    let appleSiliconStatus:      String?
    let supportsIosAppInstalls:  Bool?
}

private struct JamfPurchasing: Decodable {
    let warrantyDate:    String?
    let vendor:          String?
    let appleCareId:     String?
    let purchased:       Bool?
    let leased:          Bool?
    let poNumber:        String?
    let poDate:          String?
    let purchasePrice:   String?
    let lifeExpectancy:  Int?
}

private struct JamfUserAndLocation: Decodable {
    let username:     String?
    let realname:     String?
    let email:        String?
    let position:     String?
    let phone:        String?
    let departmentId: String?
    let buildingId:   String?
    let room:         String?
}

private struct JamfDiskEncryption: Decodable {
    let bootPartitionEncryptionDetails: JamfBootEncryption?
    let individualRecoveryKeyValidityStatus: String?   // "VALID" | "INVALID" | "UNKNOWN"
    let institutionalRecoveryKeyPresent:     Bool?
    let diskEncryptionConfigurationName:     String?
}

private struct JamfBootEncryption: Decodable {
    let partitionName:          String?
    let partitionFileVault2State: String?  // "ENCRYPTED" | "DECRYPTED" | "UNKNOWN"
    let partitionFileVault2Percent: Int?
}


/// Top-level paginated response from /api/v2/mobile-devices/detail
private struct JamfMobileInventoryResponse: Decodable {
    let totalCount: Int
    let results:    [JamfMobileRecord]
}

private struct JamfMobileRecord: Decodable {
    let mobileDeviceId: String   // normalised from "id" or "mobileDeviceId"; String or Int in JSON
    let deviceType:     String?  // "iOS" | "tvOS"
    let hardware:       JamfMobileHardware?
    let general:        JamfMobileGeneral?
    let userAndLocation: JamfMobileUserAndLocation?
    let purchasing:     JamfMobilePurchasing?

    // The /api/v2/mobile-devices/detail endpoint returns the device ID as "id" (not "mobileDeviceId").
    // The classic mobile API uses "mobileDeviceId". We handle both so the decoder never silently
    // drops records due to a missing key — which was the root cause of rawMobile always being empty.
    // Jamf also sometimes returns the id as a JSON integer instead of a string.
    private enum CodingKeys: String, CodingKey {
        case id, mobileDeviceId, deviceType, hardware, general, userAndLocation, purchasing
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Try "id" first (v2 detail endpoint), fall back to "mobileDeviceId" (classic API)
        if let s = try? c.decode(String.self, forKey: .id) {
            mobileDeviceId = s
        } else if let n = try? c.decode(Int.self, forKey: .id) {
            mobileDeviceId = String(n)
        } else if let s = try? c.decode(String.self, forKey: .mobileDeviceId) {
            mobileDeviceId = s
        } else {
            mobileDeviceId = String(try c.decode(Int.self, forKey: .mobileDeviceId))
        }
        deviceType      = try? c.decode(String.self,                      forKey: .deviceType)
        hardware        = try? c.decode(JamfMobileHardware.self,          forKey: .hardware)
        general         = try? c.decode(JamfMobileGeneral.self,           forKey: .general)
        userAndLocation = try? c.decode(JamfMobileUserAndLocation.self,   forKey: .userAndLocation)
        purchasing      = try? c.decode(JamfMobilePurchasing.self,        forKey: .purchasing)
    }
}

private struct JamfMobileHardware: Decodable {
    let serialNumber:        String?
    let model:               String?
    let modelIdentifier:     String?
    let wifiMacAddress:      String?
    let bluetoothMacAddress: String?
    // Note: osVersion/osBuild are in general section, not hardware, for mobile devices
}

private struct JamfMobileGeneral: Decodable {
    let udid:                    String?
    let displayName:             String?   // confirmed field name from real API response
    let managed:                 Bool?     // in general{} for mobile (not remoteManagement)
    let supervised:              Bool?
    let lastInventoryUpdateDate: String?
    let lastEnrolledDate:        String?
    let ipAddress:               String?
    let osVersion:               String?
    let osBuild:                 String?
    let managementId:            String?
}

private struct JamfMobileUserAndLocation: Decodable {
    let username:   String?
    let realName:   String?
    let emailAddress: String?
    let position:   String?
    let phoneNumber: String?
    let room:       String?
    let department: String?
    let building:   String?
}

private struct JamfMobilePurchasing: Decodable {
    let purchased:          Bool?
    let poNumber:           String?
    let vendor:             String?
    let appleCareId:        String?
    let purchasePrice:      String?
    let poDate:             String?
    let warrantyDate:       String?   // some Jamf versions use warrantyDate
    let warrantyExpiresDate: String?  // others use warrantyExpiresDate (full ISO8601)

    // Normalised accessor — whichever field is populated, extract YYYY-MM-DD
    var resolvedWarrantyDate: String? {
        let raw = warrantyDate ?? warrantyExpiresDate
        guard let r = raw, !r.isEmpty else { return nil }
        return r.count >= 10 ? String(r.prefix(10)) : r
    }

    // writeWarrantyBackMobile sends poDate to Jamf's mobile v2 API as a full
    // ISO8601 datetime (it rejects a bare date), and Jamf echoes it back that way.
    // Normalise to YYYY-MM-DD on read so the "changed in console?" comparison in
    // the merge doesn't see "2019-01-01T00:00:00.000Z" != "2019-01-01" and
    // re-queue the device for write-back on every sync. See ARCHITECTURE.md.
    var resolvedPoDate: String? {
        guard let r = poDate, !r.isEmpty else { return nil }
        return r.count >= 10 ? String(r.prefix(10)) : r
    }
}

// MARK: - JamfService

actor JamfService {

    private let baseURL:      String  // trailing slash already stripped
    private let clientId:     String
    private let clientSecret: String
    private let environmentId: UUID   // S1: token cache namespace — immutable, passed at init
    private let tokenIdentity: String // S1: SHA-256(origin + clientId) the cached token is bound to
    // S9: this environment's scoped log — every diagnostic here is about one env's run.
    private let log: LogService

    private var cachedToken: String?
    private var tokenExpiry: Date = .distantPast
    private var tokenTTL:    Int  = 1800  // last known TTL — used for adaptive buffer

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest  = 30
        cfg.timeoutIntervalForResource = 180
        cfg.waitsForConnectivity       = true
        cfg.requestCachePolicy         = .reloadIgnoringLocalCacheData
        // Allow up to 8 concurrent connections to the Jamf host — one per concurrent PATCH task.
        // Default is 6 (HTTP/1.1) which causes tasks to share connections and hit -999 cancellations
        // when Jamf Cloud's load balancer closes a shared keep-alive connection mid-flight.
        cfg.httpMaximumConnectionsPerHost = 8
        // Disable HTTP pipelining — Jamf Pro does not reliably support pipelined requests,
        // and pipelining on a shared connection is a second cause of -999 cancellations.
        cfg.httpShouldUsePipelining = false
        return URLSession(configuration: cfg, delegate: TLSDelegate(), delegateQueue: nil)
    }()

    init(credentials: JamfCredentials, environmentId: UUID, log: LogService) {
        let normalizedURL = credentials.url.hasSuffix("/")
            ? String(credentials.url.dropLast())
            : credentials.url
        self.baseURL       = normalizedURL
        self.clientId      = credentials.clientId
        self.clientSecret  = credentials.clientSecret
        self.environmentId = environmentId
        self.tokenIdentity = KeychainService.tokenIdentity(origin: normalizedURL, clientId: credentials.clientId)
        self.log           = log
    }

    // MARK: - Public: fetch all computers

    /// Mirrors device_sync.py → _JamfClient.fetch_all_computers()
    func fetchComputers(
        pageSize: Int = 200,
        onProgress: @Sendable @MainActor (Int, Int) -> Void
    ) async throws -> [RawJamfComputer] {

        let clampedPageSize = min(max(pageSize, 10), 2000)
        var results: [RawJamfComputer] = []
        var page    = 0
        var total   = Int.max

        await onProgress(0, 0)

        while results.count < total {
            try Task.checkCancellation()
            // Refresh token per page — validToken() checks in-memory cache first
            // (60s buffer) so this is a free date comparison on most iterations.
            // Prevents 401 mid-fetch when Jamf token TTL is shorter than the total
            // fetch time (e.g. PROD servers configured with ~3 min TTL at 40k+ devices).
            let token = try await validToken()

            // section must be sent as repeated query items — same as Python's list param
            // URLComponents doesn't deduplicate, so build URL manually.
            let urlStr = baseURL + "/api/v4/computers-inventory"
            guard var components = URLComponents(string: urlStr) else {
                throw JamfError.networkError("Invalid Jamf URL: \(urlStr)")
            }
            components.queryItems = [
                URLQueryItem(name: "section",    value: "GENERAL"),
                URLQueryItem(name: "section",    value: "HARDWARE"),
                URLQueryItem(name: "section",    value: "OPERATING_SYSTEM"),
                URLQueryItem(name: "section",    value: "PURCHASING"),
                URLQueryItem(name: "section",    value: "USER_AND_LOCATION"),
                URLQueryItem(name: "section",    value: "DISK_ENCRYPTION"),
                URLQueryItem(name: "page",       value: String(page)),
                URLQueryItem(name: "page-size",  value: String(clampedPageSize)),
                URLQueryItem(name: "sort",       value: "general.name:asc"),
            ]

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "AxMJamfSync/\($0)" } ?? "AxMJamfSync/1.1", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            try await validateHTTP(response, data: data, context: "Jamf /api/v4/computers-inventory page \(page)")

            let decoded = try JSONDecoder().decode(JamfInventoryResponse.self, from: data)

            if page == 0 {
                total = decoded.totalCount
                await onProgress(0, total)
                await log.debug("[Jamf] Page 0 — totalCount=\(decoded.totalCount)")
            }

            let batch = decoded.results
            if batch.isEmpty { break }

            // Build id→rawRecord dict once per page for O(1) per-record JSON lookup
            var rawRecordById: [String: [String: Any]] = [:]
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let records = json["results"] as? [[String: Any]] {
                for rec in records {
                    if let id = rec["id"] as? String { rawRecordById[id] = rec }
                }
            }

            for record in batch {
                let hw     = record.hardware
                let serial = ((hw?.serialNumber ?? "")).uppercased().trimmingCharacters(in: .whitespaces)
                guard !serial.isEmpty else { continue }

                let g  = record.general
                let p  = record.purchasing
                let ul = record.userAndLocation
                let de = record.diskEncryption
                let os = record.operatingSystem
                let managed = g?.remoteManagement?.managed ?? false

                // P10: Use compact JSON (no .prettyPrinted) for the stored blob.
                // Pretty-printing adds ~3× size overhead per record with no benefit in storage.
                let recordRawJson: Data? = rawRecordById[record.id].flatMap {
                    try? JSONSerialization.data(withJSONObject: $0)
                }

                results.append(RawJamfComputer(
                    jamfId:              record.id,
                    serialNumber:        serial,
                    udid:                record.udid ?? g?.udid,  // udid is top-level; g?.udid always nil
                    name:                g?.name,
                    managed:             managed,
                    managementUsername:  g?.remoteManagement?.managementUsername,
                    platform:            g?.platform,
                    supervised:          g?.supervised,
                    mdmCapable:          g?.mdmCapable?.capable,
                    enrolledViaADE:      g?.enrolledViaAutomatedDeviceEnrollment,
                    model:               hw?.model,
                    modelIdentifier:     hw?.modelIdentifier,
                    macAddress:          hw?.macAddress,
                    altMacAddress:       hw?.altMacAddress,
                    processorType:       hw?.processorType,
                    processorArch:       hw?.processorArchitecture,
                    processorSpeedMhz:   hw?.processorSpeedMhz,
                    numberOfCores:       hw?.numberOfCores,
                    totalRamMegabytes:   hw?.totalRamMegabytes,
                    batteryCapacityPercent: hw?.batteryCapacityPercent,
                    appleSiliconStatus:  hw?.appleSiliconStatus,
                    reportDate:          g?.reportDate,
                    lastCheckIn:         g?.lastCheckIn,
                    enrolledDate:        g?.lastEnrolledDate,
                    mdmCertificateExpiration: g?.mdmProfileExpiration,
                    initialEntryDate:    g?.initialEntryDate,
                    managementId:        g?.managementId,
                    warrantyDate:        p?.warrantyDate,
                    vendor:              p?.vendor,
                    appleCareId:         p?.appleCareId,
                    purchased:           p?.purchased,
                    leased:              p?.leased,
                    poNumber:            p?.poNumber,
                    poDate:              p?.poDate,
                    purchasePrice:       p?.purchasePrice,
                    lifeExpectancy:      p?.lifeExpectancy,
                    username:            ul?.username,
                    realname:            ul?.realname,
                    email:               ul?.email,
                    position:            ul?.position,
                    phone:               ul?.phone,
                    room:                ul?.room,
                    departmentId:        ul?.departmentId,
                    buildingId:          ul?.buildingId,
                    osName:              os?.name,
                    osVersion:           os?.version,
                    osBuild:             os?.build,
                    osSupplementalBuild: os?.supplementalBuildVersion,
                    osRapidResponse:     os?.rapidSecurityResponse,
                    fileVault2Status:    os?.fileVault2Status,
                    activeDirectoryStatus: os?.activeDirectoryStatus,
                    fileVaultStatus:     de?.bootPartitionEncryptionDetails?.partitionFileVault2State,
                    fileVaultPercent:    de?.bootPartitionEncryptionDetails?.partitionFileVault2Percent,
                    recoveryKeyStatus:   de?.individualRecoveryKeyValidityStatus,
                    encryptionConfig:    de?.diskEncryptionConfigurationName,
                    rawJson:             recordRawJson
                ))
            }

            page += 1
            await onProgress(results.count, total)
        }

        return results
    }

    // MARK: - Public: write back AppleCare data to Jamf purchasing fields

    /// Mirrors device_sync.py → _patch_with_backoff() + sync_jamf_writeback()
    /// PATCH /api/v4/computers-inventory-detail/{jamfId}
    /// Body: { "purchasing": { "appleCareId": "…", "warrantyDate": "YYYY-MM-DD", "vendor": "…" } }
    func writeWarrantyBack(
        jamfId:         String,
        warrantyDate:   String?,    // YYYY-MM-DD from axm_coverage_end_date
        appleCareId:    String?,    // from axm_agreement_number
        vendor:         String?,    // "purchaseSourceType (purchaseSourceId)"
        poNumber:       String?,    // from axm_order_number
        poDate:         String?,    // YYYY-MM-DD from axm_order_date
        mappingValidated: Bool = true,  // S2: false = serial→jamfId map not confirmed against this host
        token:          String? = nil  // pre-fetched token — avoids N concurrent validToken() calls
    ) async throws {

        // S2: refuse to PATCH by a jamfId whose serial mapping hasn't been re-confirmed
        // against the currently configured host. SyncEngine already filters these out;
        // this is the last-line guard so a mapping built against a different Jamf host
        // can never silently write warranty data to the wrong device.
        guard mappingValidated else {
            throw JamfError.mappingNotValidated(jamfId)
        }

        // Build the purchasing dict — only include non-empty fields (matches Python pre-flight check)
        var purchasing: [String: String] = [:]
        if let v = appleCareId,  !v.isEmpty { purchasing["appleCareId"]  = v }
        if let v = warrantyDate, !v.isEmpty { purchasing["warrantyDate"] = v }
        if let v = vendor,       !v.isEmpty { purchasing["vendor"]       = v }
        if let v = poNumber,     !v.isEmpty { purchasing["poNumber"]     = v }
        if let v = poDate,       !v.isEmpty { purchasing["poDate"]       = v }

        guard !purchasing.isEmpty else {
            throw JamfError.noDataToWrite("All coverage fields empty for jamfId=\(jamfId)")
        }

        let resolvedToken = try await { if let t = token { return t }; return try await validToken() }()
        guard let safeId = jamfId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: baseURL + "/api/v4/computers-inventory-detail/\(safeId)") else {
            throw JamfError.networkError("Invalid Jamf ID: \(jamfId)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(resolvedToken)", forHTTPHeaderField: "Authorization")
        request.setValue((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "AxMJamfSync/\($0)" } ?? "AxMJamfSync/1.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody   = try JSONSerialization.data(withJSONObject: ["purchasing": purchasing])

        let (_, response) = try await session.data(for: request)
        try validateHTTP(response, context: "Jamf PATCH /api/v4/computers-inventory-detail/\(jamfId)")
    }


    // MARK: - Public: fetch all mobile devices
    /// GET /api/v2/mobile-devices/detail?section=GENERAL&section=HARDWARE&section=USER_AND_LOCATION&section=PURCHASING
    func fetchMobileDevices(
        pageSize: Int = 200,
        onProgress: @Sendable @MainActor (Int, Int) -> Void
    ) async throws -> [RawJamfMobileDevice] {

        let clampedPageSize = min(max(pageSize, 10), 2000)
        var results: [RawJamfMobileDevice] = []
        var page    = 0
        var total   = Int.max

        await onProgress(0, 0)

        while results.count < total {
            try Task.checkCancellation()
            // Refresh token per page — same rationale as fetchComputers.
            let mobileToken = try await validToken()

            let urlStr = baseURL + "/api/v2/mobile-devices/detail"
            guard var components = URLComponents(string: urlStr) else {
                throw JamfError.networkError("Invalid Jamf URL: \(urlStr)")
            }
            components.queryItems = [
                URLQueryItem(name: "section",   value: "GENERAL"),
                URLQueryItem(name: "section",   value: "HARDWARE"),
                URLQueryItem(name: "section",   value: "USER_AND_LOCATION"),
                URLQueryItem(name: "section",   value: "PURCHASING"),
                URLQueryItem(name: "page",      value: String(page)),
                URLQueryItem(name: "page-size", value: String(clampedPageSize)),
                URLQueryItem(name: "sort",      value: "displayName:asc"),
            ]

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(mobileToken)", forHTTPHeaderField: "Authorization")
            request.setValue((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "AxMJamfSync/\($0)" } ?? "AxMJamfSync/1.1", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            try await validateHTTP(response, data: data, context: "Jamf /api/v2/mobile-devices/detail page \(page)")

            let decoded = try JSONDecoder().decode(JamfMobileInventoryResponse.self, from: data)

            if page == 0 {
                total = decoded.totalCount
                await onProgress(0, total)
                await log.debug("[Jamf] Mobile page 0 — totalCount=\(decoded.totalCount), decoded \(decoded.results.count) records")
            }

            let batch = decoded.results
            if batch.isEmpty {
                await log.debug("[Jamf] Mobile page \(page) — empty batch (totalCount=\(total), collected=\(results.count)). Stopping.")
                break
            }

            // Build id→rawRecord dict for O(1) raw JSON lookup.
            // v2 mobile-devices/detail uses "id"; classic API uses "mobileDeviceId". Support both.
            var rawRecordById: [String: [String: Any]] = [:]
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let records = json["results"] as? [[String: Any]] {
                for rec in records {
                    let idStr: String?
                    if      let s = rec["id"] as? String             { idStr = s }
                    else if let n = rec["id"] as? Int                { idStr = String(n) }
                    else if let s = rec["mobileDeviceId"] as? String { idStr = s }
                    else if let n = rec["mobileDeviceId"] as? Int    { idStr = String(n) }
                    else                                              { idStr = nil }
                    if let id = idStr { rawRecordById[id] = rec }
                }
            }

            for record in batch {
                let hw  = record.hardware
                let g   = record.general
                let ul  = record.userAndLocation
                let p   = record.purchasing
                // serialNumber is in hardware{} — confirmed from real API response
                let serial = (hw?.serialNumber ?? "").uppercased().trimmingCharacters(in: .whitespaces)
                guard !serial.isEmpty else {
                    await log.debug("[Jamf] Mobile: skipping record — empty serial (mobileDeviceId=\(record.mobileDeviceId))")
                    continue
                }

                // OS version lives in general.osVersion per the mobile inventory API
                // (unlike computers where it's in operatingSystem section)
                let osVer = g?.osVersion

                // resolvedWarrantyDate handles both warrantyDate and warrantyExpiresDate
                // field names (Jamf version differences) and normalises to YYYY-MM-DD.
                let warrantyDate: String? = p?.resolvedWarrantyDate

                let recordRawJson: Data? = rawRecordById[record.mobileDeviceId].flatMap {
                    try? JSONSerialization.data(withJSONObject: $0)
                }

                results.append(RawJamfMobileDevice(
                    jamfId:           record.mobileDeviceId,
                    serialNumber:     serial,
                    udid:             g?.udid,
                    name:             g?.displayName,
                    deviceType:       record.deviceType ?? "iOS",
                    managed:          g?.managed ?? false,
                    supervised:       g?.supervised,
                    model:            hw?.model,
                    modelIdentifier:  hw?.modelIdentifier,
                    wifiMacAddress:   hw?.wifiMacAddress,
                    osVersion:        osVer,
                    osBuild:          g?.osBuild,
                    lastInventoryUpdate: g?.lastInventoryUpdateDate,
                    lastEnrolledDate: g?.lastEnrolledDate,
                    ipAddress:        g?.ipAddress,
                    warrantyDate:     warrantyDate,
                    vendor:           p?.vendor,
                    appleCareId:      p?.appleCareId,
                    purchased:        p?.purchased,
                    poNumber:         p?.poNumber,
                    poDate:           p?.resolvedPoDate,
                    purchasePrice:    p?.purchasePrice,
                    username:         ul?.username,
                    realname:         ul?.realName,
                    email:            ul?.emailAddress,
                    position:         ul?.position,
                    phone:            ul?.phoneNumber,
                    room:             ul?.room,
                    department:       ul?.department,
                    building:         ul?.building,
                    rawJson:          recordRawJson
                ))
            }

            page += 1
            await onProgress(results.count, total)
        }

        return results
    }

    // MARK: - Public: write back AppleCare data to mobile device purchasing fields
    /// PATCH /api/v2/mobile-devices/{mobileDeviceId}
    /// Body: { "ios": { "purchasing": { "appleCareId": "…", "vendor": "…", "warrantyExpiresDate": "…" } } }
    func writeWarrantyBackMobile(
        mobileDeviceId: String,
        serialNumber:   String,     // fallback `name` — see the blank-name retry below
        warrantyDate:   String?,    // YYYY-MM-DD — converted to ISO8601 for mobile API
        appleCareId:    String?,
        vendor:         String?,    // "purchaseSourceType (purchaseSourceId)"
        poNumber:       String?,    // from axm_order_number
        poDate:         String?,    // YYYY-MM-DD from axm_order_date
        mappingValidated: Bool = true,  // S2: see writeWarrantyBack
        token:          String? = nil  // pre-fetched token
    ) async throws {

        // S2: last-line guard — see writeWarrantyBack.
        guard mappingValidated else {
            throw JamfError.mappingNotValidated(mobileDeviceId)
        }

        var purchasing: [String: String] = [:]
        if let v = appleCareId,  !v.isEmpty { purchasing["appleCareId"]         = v }
        if let v = vendor,       !v.isEmpty { purchasing["vendor"]              = v }
        if let v = poNumber,     !v.isEmpty { purchasing["poNumber"]            = v }
        // Mobile PATCH requires ISO8601 full date-time for all date fields
        if let v = poDate,       !v.isEmpty {
            let isoPoDate = v.count == 10 ? v + "T00:00:00.000Z" : v
            purchasing["poDate"] = isoPoDate
        }
        if let v = warrantyDate, !v.isEmpty {
            let iso = v.count == 10 ? v + "T00:00:00.000Z" : v
            purchasing["warrantyExpiresDate"] = iso
        }

        guard !purchasing.isEmpty else {
            throw JamfError.noDataToWrite("All coverage fields empty for mobileDeviceId=\(mobileDeviceId)")
        }

        let resolvedToken = try await { if let t = token { return t }; return try await validToken() }()
        guard let safeId = mobileDeviceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: baseURL + "/api/v2/mobile-devices/\(safeId)") else {
            throw JamfError.networkError("Invalid mobile device ID: \(mobileDeviceId)")
        }

        func send(_ body: [String: Any]) async throws -> (Data, URLResponse) {
            var request = URLRequest(url: url)
            request.httpMethod = "PATCH"
            request.setValue("Bearer \(resolvedToken)", forHTTPHeaderField: "Authorization")
            request.setValue((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "AxMJamfSync/\($0)" } ?? "AxMJamfSync/1.1", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return try await session.data(for: request)
        }

        let (data, response) = try await send(["ios": ["purchasing": purchasing]])

        // Found via manual repro: a mobile device with no `name` set in Jamf
        // rejects ANY purchasing-only PATCH with 400 INVALID_FIELD "name cannot
        // be blank" — even though name isn't part of this request at all.
        // Retry once, resending the same purchasing payload plus `name` (the
        // serial number, since that's always available and stable). Jamf
        // persists the name from that retry, so this is self-healing: every
        // later write-back for this device succeeds on the first attempt.
        if let http = response as? HTTPURLResponse, http.statusCode == 400,
           Self.isBlankNameError(data) {
            await log.warn("[Jamf] Mobile PATCH \(mobileDeviceId) rejected — device has no name set in Jamf. Retrying once with name=\(serialNumber).")
            let (retryData, retryResponse) = try await send(["name": serialNumber, "ios": ["purchasing": purchasing]])
            try await validateHTTP(retryResponse, data: retryData,
                context: "Jamf PATCH /api/v2/mobile-devices/\(mobileDeviceId) (retry with name=serial)")
            return
        }

        try await validateHTTP(response, data: data, context: "Jamf PATCH /api/v2/mobile-devices/\(mobileDeviceId)")
    }

    /// Matches Jamf's INVALID_FIELD "name cannot be blank" error on the mobile
    /// devices v2 PATCH endpoint — see writeWarrantyBackMobile's retry above.
    /// Matched on `field == "name"` rather than the description text, since
    /// Jamf's error descriptions aren't a documented stable contract.
    private nonisolated static func isBlankNameError(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = json["errors"] as? [[String: Any]] else { return false }
        return errors.contains { ($0["field"] as? String) == "name" }
    }

    // MARK: - Token management

    func validToken() async throws -> String {
        // Adaptive buffer: never > half the TTL, min 10s, max 60s.
        // A fixed 60s buffer on a 60s TTL token means the cache is never valid.
        // e.g. TTL=60 → buffer=30s | TTL=179 → buffer=60s | TTL=1800 → buffer=60s
        let buffer = Double(max(10, min(60, tokenTTL / 2)))

        // Check in-memory cache first (fastest path)
        if let t = cachedToken, Date() < tokenExpiry.addingTimeInterval(-buffer) {
            let remaining = Int(tokenExpiry.timeIntervalSinceNow)
            await log.debug("[Jamf] Token: reusing cached token — \(remaining / 60)m \(remaining % 60)s remaining.")
            return t
        }
        // Check Keychain cache — survives app restarts.
        // Use same adaptive buffer to avoid returning a near-expired token.
        if let cached = KeychainService.loadJamfTokenForEnv(identity: tokenIdentity, envId: environmentId),
           Date() < cached.expiry.addingTimeInterval(-Double(max(10, min(60, cached.ttl / 2)))) {
            cachedToken = cached.token
            tokenExpiry = cached.expiry
            tokenTTL    = cached.ttl
            let remaining = Int(cached.expiry.timeIntervalSinceNow)
            await log.debug("[Jamf] Token: restored from Keychain — \(remaining / 60)m \(remaining % 60)s remaining.")
            return cached.token
        }
        await log.debug("[Jamf] Token: fetching fresh token from \(baseURL)/api/v1/oauth/token…")
        let (token, ttl) = try await fetchToken()
        cachedToken = token
        tokenTTL    = ttl
        tokenExpiry = Date().addingTimeInterval(TimeInterval(ttl))
        KeychainService.saveJamfTokenForEnv(token, expiry: tokenExpiry, ttl: ttl, identity: tokenIdentity, envId: environmentId)
        await log.debug("[Jamf] Token: received — TTL \(ttl)s (\(ttl / 60)m). Saved to Keychain.")
        return token
    }

    /// Call on app exit or sync stop — clears memory cache and revokes the token server-side.
    /// Jamf endpoint: POST /api/v1/auth/invalidate-token  (no body, Bearer header)
    func invalidateToken() async {
        guard let token = cachedToken else { return }
        cachedToken = nil
        tokenExpiry = .distantPast
        // S2: Evict from Keychain so the next launch fetches fresh.
        KeychainService.clearJamfTokenForEnv(id: environmentId)
        // Best-effort server-side revoke — ignore errors (safe URL construction)
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        if var components = URLComponents(string: base),
           let revokeURL = { components.path = "/api/v1/auth/invalidate-token"; return components.url }() {
            var req = URLRequest(url: revokeURL)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "AxMJamfSync/\($0)" } ?? "AxMJamfSync/1.1", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 10
            _ = try? await session.data(for: req)
        }
    }

    /// Clear in-memory token without a server call (for ABM — Apple has no revoke endpoint).
    func clearToken() {
        cachedToken = nil
        tokenExpiry = .distantPast
        // S2: Evict from Keychain (mirrors invalidateToken without the server call).
        KeychainService.clearJamfTokenForEnv(id: environmentId)
    }

    private func fetchToken() async throws -> (token: String, ttl: Int) {
        // S1: Use URLComponents to safely build the token URL.
        // String concatenation breaks when baseURL has a trailing slash or query chars.
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var components = URLComponents(string: base) else {
            throw JamfError.invalidURL(baseURL)
        }
        components.path = "/api/v1/oauth/token"
        guard let tokenURL = components.url else {
            throw JamfError.invalidURL(baseURL)
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Percent-encode credentials — secrets may contain &, =, + characters
        func pct(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
                .replacingOccurrences(of: "+", with: "%2B")
                .replacingOccurrences(of: "&", with: "%26")
                .replacingOccurrences(of: "=", with: "%3D") ?? s
        }
        request.httpBody = "grant_type=client_credentials&client_id=\(pct(clientId))&client_secret=\(pct(clientSecret))".data(using: .utf8)
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            await log.error("[Jamf] Token endpoint HTTP 401 — check clientId/clientSecret. Response: \(LogService.sanitizedResponseBody(data))")
            throw JamfError.authError("Jamf token rejected (401) — check clientId/clientSecret")
        }
        try await validateHTTP(response, data: data, context: "Jamf /api/v1/oauth/token")

        let decoded = try JSONDecoder().decode(JamfTokenResponse.self, from: data)
        return (decoded.access_token, decoded.expires_in)
    }

    // MARK: - HTTP validation

    private func validateHTTP(_ response: URLResponse, context: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw JamfError.networkError("\(context): no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JamfError.httpError(context: context, statusCode: http.statusCode)
        }
    }

    private func validateHTTP(_ response: URLResponse, data: Data, context: String) async throws {
        guard let http = response as? HTTPURLResponse else {
            await log.error("[Jamf] \(context): no HTTP response.")
            throw JamfError.networkError("\(context): no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            await log.error("[Jamf] \(context) HTTP \(http.statusCode) — \(LogService.sanitizedResponseBody(data))")
            throw JamfError.httpError(context: context, statusCode: http.statusCode)
        }
    }
}

// MARK: - Output types (Sendable)

struct RawJamfComputer: Sendable {
    // Identity
    let jamfId:              String
    let serialNumber:        String
    let udid:                String?
    let name:                String?
    // General
    let managed:             Bool
    let managementUsername:  String?
    let platform:            String?
    let supervised:          Bool?
    let mdmCapable:          Bool?
    let enrolledViaADE:      Bool?
    // Hardware
    let model:               String?
    let modelIdentifier:     String?
    let macAddress:          String?
    let altMacAddress:       String?
    let processorType:       String?
    let processorArch:       String?
    let processorSpeedMhz:   Int?
    let numberOfCores:       Int?
    let totalRamMegabytes:   Int?
    let batteryCapacityPercent: Int?
    let appleSiliconStatus:  String?
    // General dates
    let reportDate:          String?
    let lastCheckIn:         String?   // renamed from lastContactTime in v4
    let enrolledDate:        String?
    let mdmCertificateExpiration: String?
    let initialEntryDate:    String?   // "Enrolled Date" in UI — first-added-to-Jamf date, distinct from enrolledDate (most recent re-enrollment)
    let managementId:        String?
    // Purchasing
    let warrantyDate:        String?
    let vendor:              String?
    let appleCareId:         String?
    let purchased:           Bool?
    let leased:              Bool?
    let poNumber:            String?
    let poDate:              String?
    let purchasePrice:       String?
    let lifeExpectancy:      Int?
    // User and Location
    let username:            String?
    let realname:            String?
    let email:               String?
    let position:            String?
    let phone:               String?
    let room:                String?
    let departmentId:        String?
    let buildingId:          String?
    // Operating System
    let osName:              String?
    let osVersion:           String?
    let osBuild:             String?
    let osSupplementalBuild: String?
    let osRapidResponse:     String?
    let fileVault2Status:    String?
    let activeDirectoryStatus: String?
    // Disk Encryption
    let fileVaultStatus:     String?
    let fileVaultPercent:    Int?
    let recoveryKeyStatus:   String?
    let encryptionConfig:    String?
    // Raw JSON blob for full detail display
    let rawJson:             Data?
}


struct RawJamfMobileDevice: Sendable {
    // Identity
    let jamfId:           String
    let serialNumber:     String
    let udid:             String?
    let name:             String?
    let deviceType:       String    // "iOS" | "tvOS"
    // General
    let managed:          Bool
    let supervised:       Bool?
    let model:            String?
    let modelIdentifier:  String?
    let wifiMacAddress:   String?
    let osVersion:        String?
    let osBuild:          String?
    let lastInventoryUpdate: String?
    let lastEnrolledDate: String?
    let ipAddress:        String?
    // Purchasing
    let warrantyDate:     String?
    let vendor:           String?
    let appleCareId:      String?
    let purchased:        Bool?
    let poNumber:         String?
    let poDate:           String?
    let purchasePrice:    String?
    // User and Location
    let username:         String?
    let realname:         String?
    let email:            String?
    let position:         String?
    let phone:            String?
    let room:             String?
    let department:       String?
    let building:         String?
    // Raw JSON blob
    let rawJson:          Data?
}

// MARK: - JamfError

enum JamfError: LocalizedError {
    case authError(String)
    case networkError(String)
    case httpError(context: String, statusCode: Int)
    case noDataToWrite(String)
    case invalidURL(String)    // S1: malformed base URL
    case mappingNotValidated(String)   // S2: serial→jamfId map not confirmed against the current host

    var errorDescription: String? {
        switch self {
        case .authError(let m):             return "Jamf: Auth failed — \(m)"
        case .networkError(let m):          return "Jamf: Network error — \(m)"
        case .httpError(let ctx, let code): return "Jamf: HTTP \(code) from \(ctx)"
        case .noDataToWrite(let m):         return "Jamf: No data — \(m)"
        case .invalidURL(let u):            return "Jamf: Invalid URL — \(u)"
        case .mappingNotValidated(let id):  return "Jamf: mapping pending revalidation for id \(id) — skipped"
        }
    }
}

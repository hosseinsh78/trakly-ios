import Foundation

/// Constants mirrored from `extension/src/protocol.js` (docs/specs/phase9-phone-capture.md D11, D12; phase 10 §B8), plus
/// the app limits of phase 10 §B15: the port of Android's `core/Limits.kt`. `LimitsTests` reads `protocol.js` when the
/// repository has it (the private repository; the public iOS mirror has no extension sources) and
/// `shared/contracts/bridge.json` always.
public enum Limits {
    /// Every entry of `LIMITS` in `protocol.js`, by its JavaScript name (milliseconds, bytes, counts), in its order.
    public static let limits: [(String, Int64)] = [
        ("captureBytes", 900_000),
        ("keptNodes", 300),
        ("ldBlocks", 40),
        ("ldChars", 300_000),
        ("metaValues", 12),
        ("metaChars", 2048),
        ("urlChars", 2048),
        ("titleChars", 500),
        ("shopifyImages", 60),
        ("shopifyOptions", 8),
        ("shopifyVariants", 300),
        ("metaSettleMs", 4000),
        ("livePingMs", 2500),
        ("readsPerMinute", 10),
        ("readsPerHour", 120),
        ("imagesPer10Min", 40),
        ("imageBytes", 8 * 1024 * 1024),
        ("pollMs", 700),
        ("readDeadlineMs", 30_000),
        ("challengeSurfaceMs", 5000),
        ("challengeDeadlineMs", 120_000),
        ("noneSurfaceMs", 4000),
        ("noneGiveUpMs", 10_000),
        ("deniedMs", 8000),
        ("pendingMs", 15 * 60_000),
        ("readTabsSweepMs", 10 * 60_000),
    ]

    public static func limit(_ name: String) -> Int64 {
        limits.first { $0.0 == name }?.1 ?? 0
    }

    // MARK: - policy lists (D11 of phase 9, §I3)

    /// `PERSONAL_PATH`: account, cart and wishlist paths are never read.
    public static let personalPath =
        "(^|/)(account|my-?account|customer|orders?|order-history|wishlist|wish-list|favou?rites|saved|cart|basket|bag|" +
        "checkout|profile|login|sign-?in|register)(/|$)"

    /// `DENY_HOSTS`: hosts never read.
    public static let denyHosts: [String] = [
        "accounts.google.com",
        "mail.google.com",
        "myaccount.google.com",
        "drive.google.com",
        "docs.google.com",
        "login.live.com",
        "outlook.live.com",
        "outlook.office.com",
        "outlook.office365.com",
        "login.microsoftonline.com",
        "appleid.apple.com",
        "icloud.com",
        "www.icloud.com",
        "web.whatsapp.com",
        "web.telegram.org",
        "accounts.firefox.com",
        "addons.mozilla.org",
        "chromewebstore.google.com",
        "chrome.google.com",
    ]

    /// `DENY_SUFFIXES`: hosts never read, with every subdomain (Trakly itself among them).
    public static let denySuffixes: [String] = [
        "trakly.info",
        "shaparak.ir",
        "gov",
        "gov.ir",
        "mil",
        "bank",
        "nip.io",
        "sslip.io",
        "xip.io",
        "localtest.me",
        "lvh.me",
        "vcap.me",
        "traefik.me",
    ]

    /// `RESERVED_SUFFIXES`: local and reserved names.
    public static let reservedSuffixes: [String] = [
        "localhost",
        "local",
        "localdomain",
        "internal",
        "intranet",
        "lan",
        "home",
        "home.arpa",
        "corp",
        "private",
        "arpa",
        "test",
        "example",
        "invalid",
        "onion",
    ]

    /// `DEV_ORIGINS`: the local origins a debug build may read fixture shops from (§B8, §E5). Only in a debug build of
    /// this package: a release build has none, so no local origin string ships to the store (`source.check.mjs`).
    public static let devOrigins: [String] = {
        #if DEBUG
            return ["http://localhost:8000", "http://127.0.0.1:8000", "http://10.0.2.2:8000"]
        #else
            return []
        #endif
    }()

    /// `DEV_SHOP_PATH`: the path of the local fixture shops (debug builds only, as `devOrigins`).
    public static let devShopPath: String = {
        #if DEBUG
            return "/dev/shop/"
        #else
            return ""
        #endif
    }()

    // MARK: - read loop (D12 of phase 9)

    public static let pollMs = limit("pollMs")
    public static let readDeadlineMs = limit("readDeadlineMs")
    public static let challengeSurfaceMs = limit("challengeSurfaceMs")
    public static let challengeDeadlineMs = limit("challengeDeadlineMs")
    public static let noneSurfaceMs = limit("noneSurfaceMs")
    public static let noneGiveUpMs = limit("noneGiveUpMs")
    public static let deniedMs = limit("deniedMs")
    public static let metaSettleMs = limit("metaSettleMs")
    public static let urlChars = Int(limit("urlChars"))
    public static let captureBytes = Int(limit("captureBytes"))
    public static let pendingMs = limit("pendingMs")

    /// The stage text turns to «سایت فروشنده کند پاسخ می دهد…» after this long without a product (app only).
    public static let slowMs: Int64 = 8000

    // MARK: - reads (phase 8 LIMITS, §B5)

    public static let readsPerMinute = Int(limit("readsPerMinute"))
    public static let readsPerHour = Int(limit("readsPerHour"))

    // MARK: - script results

    /// A probe answer larger than this is refused before it is parsed.
    public static let summaryMaxChars = 16 * 1024

    /// `op:'capture'`.
    public static let captureMaxChars = 2_000_000

    /// Shopify JSON: `shopify_ready` is polled this often, for at most this long.
    public static let shopifyPollMs: Int64 = 300
    public static let shopifyWaitMs: Int64 = 5000

    /// A probe without an answer for this long no longer blocks the next probe.
    public static let probeStaleMs: Int64 = 3000

    /// An extraction step without an answer: read the page again.
    public static let extractStepMs: Int64 = 10_000

    /// The size rungs of the asset's `op:'capture'` (0 to 3).
    public static let maxRung = 3

    // MARK: - images (D11, §B15, §I3)

    public static let imagesMax = 6
    public static let imageBytes = Int(limit("imageBytes"))
    public static let imageTimeoutMs: Int64 = 15_000

    /// A fetched product image is stored as JPEG of at most this edge (quality 0.85).
    public static let imageEdgePx = 2048
    public static let imageQuality = 0.85

    // MARK: - the app (§B15)

    /// Live panel WebViews in `stacks`: the primary, the selected tab, the modal.
    public static let liveWebViews = 3

    /// The launch cover ends at `ready`, at most this long after the first commit, and this long overall.
    public static let splashAfterCommitMs: Int64 = 1500
    public static let splashMaxMs: Int64 = 3000

    /// `intake.fetch`: one request at most this long; a ready host WebView is awaited this long.
    public static let intakeFetchMs: Int64 = 35_000
    public static let hostWaitMs: Int64 = 10_000

    /// `back` is answered by the page within this.
    public static let backReplyMs: Int64 = 500

    /// Image refs, intake ids: 30 min; a pending single-mode choice: 15 min; the basket: 30 min, 20 lines.
    public static let refMs: Int64 = 30 * 60_000
    public static let intakeIdMs: Int64 = 30 * 60_000
    public static let pendingChoiceMs: Int64 = 15 * 60_000
    public static let basketMs: Int64 = 30 * 60_000
    public static let basketMax = 20

    /// `file.save`: decoded bytes; native `download`: bytes; both kept in app-private storage for a day.
    public static let fileSaveBytes = 10 * 1024 * 1024
    public static let downloadBytes: Int64 = 50 * 1024 * 1024
    public static let fileKeepMs: Int64 = 24 * 3_600_000
    public static let downloadHops = 3

    /// Pull to refresh: the spinner stops at the next `page` or after this.
    public static let refreshMaxMs: Int64 = 10_000

    /// A pop waits this long for the next `page` before the WebView moves down (§E3).
    public static let popPageWaitMs: Int64 = 300

    /// Shared links of the iOS share extension: at most this many, for this long (D20, §B15).
    public static let sharedLinksMax = 10
    public static let sharedLinksMs: Int64 = 24 * 3_600_000

    /// The app lock locks again after this long in the background (D21).
    public static let lockAfterMs: Int64 = 5 * 60_000
}

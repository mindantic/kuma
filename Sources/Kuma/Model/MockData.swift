import Foundation
import KumaCore

enum MockData {
    static let kokoroVoices: [VoiceOption] = [
        VoiceOption(id: "am_onyx", name: "Onyx, deep male"),
        VoiceOption(id: "am_adam", name: "Adam, male"),
        VoiceOption(id: "am_michael", name: "Michael, male"),
        VoiceOption(id: "am_fenrir", name: "Fenrir, male"),
        VoiceOption(id: "am_puck", name: "Puck, male"),
        VoiceOption(id: "af_heart", name: "Heart, female"),
        VoiceOption(id: "af_bella", name: "Bella, female"),
        VoiceOption(id: "af_nicole", name: "Nicole, whisper"),
        VoiceOption(id: "af_sarah", name: "Sarah, female"),
        VoiceOption(id: "af_sky", name: "Sky, female"),
        VoiceOption(id: "bm_george", name: "George, British male"),
        VoiceOption(id: "bm_lewis", name: "Lewis, British male"),
        VoiceOption(id: "bm_fable", name: "Fable, British male"),
        VoiceOption(id: "bf_emma", name: "Emma, British female"),
        VoiceOption(id: "bf_isabella", name: "Isabella, British female"),
    ]

    static let builtInPersonas: [Persona] = PersonaLibrary.builtIns

    static let toolStatus: [Tool: ToolStatus] = [
        .claude: ToolStatus(binaryFound: true, hookInstalled: true),
        .opencode: ToolStatus(binaryFound: true, hookInstalled: false),
        .codex: ToolStatus(binaryFound: true, hookInstalled: true),
        .cursor: ToolStatus(binaryFound: false, hookInstalled: false),
    ]

    static func settings() -> KumaSettings {
        var settings = KumaSettings()
        settings.summaryModels = ["claude": "haiku", "opencode": "anthropic/claude-haiku-4-5", "codex": "gpt-5-mini"]
        settings.projectPrefs["infra"] = SessionPrefs(highOnly: true)
        settings.sessionPrefs["s-docs-1"] = SessionPrefs(muted: true)
        settings.customPersonas = [
            Persona(id: "custom-pirate", name: "Straw Hat", voice: "am_puck", speed: 1.15, tone: "Loud, cheerful pirate. Short shouts, calls sessions crewmates."),
        ]
        return settings
    }

    static func sessions(now: Date = Date()) -> [Session] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let base = "/Users/dev/Codes"
        return [
            Session(id: "s-billing-1", tool: .claude, project: "billing-api", cwd: "\(base)/billing-api", title: "Migrate invoices to Stripe v2", model: "opus 4.1", terminal: "iTerm2", status: .needsApproval, statusSince: ago(2), lastSummary: "Wants to run the database migration on staging.", lastMessage: "I have prepared migration 0042_invoice_v2. It renames three columns and backfills 18k rows. Shall I run `npm run migrate:staging`?\n\nThe rollback script is in scripts/rollback_0042.sql.", pendingDetail: "Bash: npm run migrate:staging"),
            Session(id: "s-web-1", tool: .opencode, project: "storefront-web", cwd: "\(base)/storefront-web", title: "Checkout redesign", model: "claude-sonnet-4-5", terminal: "Ghostty", status: .question, statusSince: ago(6), lastSummary: "Asks whether to keep the old coupon field or merge it into the promo box.", lastMessage: "Two options for coupons:\n1. Keep the separate coupon field.\n2. Merge it into the promo box.\nWhich do you prefer?"),
            Session(id: "s-infra-1", tool: .codex, project: "infra", cwd: "\(base)/infra", title: "Terraform plan for EKS upgrade", model: "gpt-5-codex", terminal: "Terminal", status: .error, statusSince: ago(11), lastSummary: "Terraform plan failed, the AWS credentials expired.", lastMessage: "Error: error configuring Terraform AWS Provider: no valid credential sources found.\nPlease run aws sso login and retry."),
            Session(id: "s-mobile-1", tool: .claude, project: "mobile-app", cwd: "\(base)/mobile-app", title: "Fix push notification crash", model: "sonnet 4.5", terminal: "Orca", status: .needsApproval, statusSince: ago(1), lastSummary: "Needs approval to edit the Info.plist entitlements.", lastMessage: "I need to add aps-environment to the entitlements file. May I edit ios/Runner/Runner.entitlements?", pendingDetail: "Edit: ios/Runner/Runner.entitlements"),
            Session(id: "s-docs-1", tool: .claude, project: "docs-site", cwd: "\(base)/docs-site", title: "Rewrite getting started guide", model: "haiku 4.5", terminal: "iTerm2", status: .done, statusSince: ago(14), lastSummary: "Rewrote four pages of the getting started guide, the build passes.", lastMessage: "Done. Updated intro.md, install.md, first-run.md and faq.md. Build passes."),
            Session(id: "s-billing-2", tool: .claude, project: "billing-api", cwd: "\(base)/billing-api", title: "Add webhook retries", model: "sonnet 4.5", terminal: "iTerm2", status: .working, statusSince: ago(9), lastSummary: "Writing retry tests for the webhook handler.", lastMessage: "Running the test suite for webhooks..."),
            Session(id: "s-search-1", tool: .cursor, project: "search-service", cwd: "\(base)/search-service", title: "Tune ranking weights", model: "gpt-5", terminal: "Ghostty", status: .working, statusSince: ago(23), lastSummary: "Benchmarking the new BM25 weights against last week.", lastMessage: "Benchmark 3 of 5 running."),
            Session(id: "s-web-2", tool: .opencode, project: "storefront-web", cwd: "\(base)/storefront-web", title: "Upgrade to Next 15", model: "gpt-5", terminal: "Ghostty", status: .done, statusSince: ago(32), lastSummary: "Moved storefront-web to Next 15, two deprecation warnings left.", lastMessage: "Next 15 upgrade complete. Remaining warnings: next/legacy/image in Hero.tsx and Footer.tsx."),
            Session(id: "s-infra-2", tool: .claude, project: "infra", cwd: "\(base)/infra", title: "Rotate staging secrets", model: "opus 4.1", terminal: "Terminal", status: .working, statusSince: ago(4), lastSummary: "Rotating secrets for eight staging services.", lastMessage: "Rotated 5 of 8."),
            Session(id: "s-ml-1", tool: .codex, project: "ml-pipeline", cwd: "\(base)/ml-pipeline", title: "Fix flaky feature store test", model: "gpt-5-codex", terminal: "Orca", status: .done, statusSince: ago(47), lastSummary: "Found the race in the cache warmup, test is stable now.", lastMessage: "The flake came from parallel cache warmup. Added a lock and ran the test 200 times, all green."),
            Session(id: "s-mobile-2", tool: .cursor, project: "mobile-app", cwd: "\(base)/mobile-app", title: "Dark mode polish", model: "sonnet 4.5", terminal: "Orca", status: .working, statusSince: ago(15), lastSummary: "Adjusting color tokens for the settings screens.", lastMessage: "Updating tokens in theme/dark.ts"),
            Session(id: "s-cli-1", tool: .claude, project: "kuma", cwd: "\(base)/kuma", title: "Summarizer prompt tuning", model: "haiku 4.5", terminal: "iTerm2", status: .ended, statusSince: ago(95), lastSummary: "Session ended after the prompt changes were merged.", lastMessage: "Merged into main."),
            Session(id: "s-auth-1", tool: .opencode, project: "auth-service", cwd: "\(base)/auth-service", title: "Passkey login", model: "claude-sonnet-4-5", terminal: "Terminal", status: .working, statusSince: ago(38), lastSummary: "Wiring WebAuthn registration endpoints.", lastMessage: "Implementing /webauthn/register/finish"),
        ]
    }

    static func recentBriefings(from sessions: [Session], voice: String) -> [Briefing] {
        let now = Date()
        return sessions.filter { $0.status != .working }.enumerated().map { index, session in
            Briefing(sessionId: session.id, project: session.project, tool: session.tool, text: session.lastSummary ?? "", priority: session.status.needsYou ? .high : .normal, voice: voice, speed: 1.0, createdAt: now.addingTimeInterval(Double(-index * 340 - 60)))
        }
    }
}

import Foundation

extension Vehicle {
    /// Mirrors the repository's normalizeClientName / normalizeTokscaleClientName identities.
    /// This is independent of a tool's localized vehicle label or selected model.
    public static func normalizeClientID(_ value: String) -> String {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let aliases = ["antigravity-cli": "antigravity", "antigravity-extension": "antigravity",
                       "micode": "mimo", "micode-desktop": "mimo", "kilocode": "kilo",
                       "devin-cli": "devin", "devin-desktop": "devin"]
        raw = aliases[raw] ?? raw
        func matches(_ pattern: String) -> Bool { raw.range(of: pattern, options: .regularExpression) != nil }
        for name in ["claude", "codex", "hermes"] where raw.contains(name) { return name }
        if raw == "goose" { return raw }
        for name in ["gemini", "cursor", "antigravity"] where raw.contains(name) { return name }
        if raw == "amp" { return raw }
        for name in ["kimi", "qwen", "grok"] where raw.contains(name) { return name }
        if raw == "droid" { return raw }
        if raw.contains("copilot") { return "copilot" }
        if raw == "senpi" || matches(#"^omo[\s_-]*native$|^senpi(?:[\s_-]*\([^)]*\))?$"#) { return "senpi" }
        if raw == "omp" || matches(#"^oh[\s_-]*my[\s_-]*pi$"#) { return "omp" }
        if matches(#"\bpi\b"#) { return "pi" }
        if raw.contains("zed") { return "zed" }
        if matches(#"^kilo[\s_-]*code$"#) { return "kilo" }
        if matches(#"command[\s_-]*code"#) { return "commandcode" }
        if raw.contains("micode") || raw.contains("mimo") { return "mimo" }
        if raw == "muse" || matches(#"^muse[\s_-]*code$"#) { return "muse" }
        for name in ["zcode", "kiro", "codebuddy", "workbuddy", "proma"] where raw.contains(name) { return name }
        if raw == "catpaw" { return raw }
        if raw.contains("qodercn") || raw == "qoder-cn" || raw == "qoder cn" { return "qodercn" }
        if raw.contains("reasonix") { return "reasonix" }
        if matches(#"cherry[\s_-]*studio"#) { return "cherrystudio" }
        if matches(#"lm[\s_-]*studio"#) { return "lmstudio" }
        if matches(#"^unsloth(?:[\s_-]+(?:studio|api))?$"#) { return "unsloth" }
        for name in ["dsh", "devin"] where raw.contains(name) { return name }
        if raw == "fx" { return raw }
        if raw == "mcode" || matches(#"^minimax[\s_-]*code$"#) { return "mcode" }
        if raw.contains("opencode") { return "opencode" }
        if ["openclaw", "clawd", "moltbot", "moldbot"].contains(where: raw.contains) { return "openclaw" }
        return raw.replacingOccurrences(of: #"[^a-z0-9_-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

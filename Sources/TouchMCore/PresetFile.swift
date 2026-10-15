import Foundation

/// Reads INI-format rule preset files into TouchM rules.
public enum PresetFile {
    public struct Result { public var rules: [CommanderRule]; public var skipped: Int; public var summary: String }

    public static func parse(_ text: String) -> Result {
        // [section] -> key -> value, with Qt's %20 escaping undone.
        var sections: [String: [String: String]] = [:]
        var cur = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("["), line.hasSuffix("]") { cur = String(line.dropFirst().dropLast()); continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).replacingOccurrences(of: "%20", with: " ")
            sections[cur, default: [:]][k] = String(line[line.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        var rules: [CommanderRule] = [], skipped = 0
        for (name, kv) in sections where name.hasPrefix("appGroup") {
            let apps = indices(kv, prefix: "appIds\\").compactMap { kv["appIds\\\($0)\\appId"] }
            for c in indices(kv, prefix: "contexts\\") {
                let base = "contexts\\\(c)\\"
                var role: String? = nil
                if kv[base + "definedByType"] == "true" {
                    role = kv[base + "elementType\\identifiers\\AXRole"] ?? kv[base + "elementType\\identifiers\\_special"]
                } else if c != 0 { skipped += indices(kv, prefix: base + "gestures\\").count; continue }   // a specific recorded UI element: not portable
                for g in indices(kv, prefix: base + "gestures\\") {
                    guard let gesture = kv[base + "gestures\\\(g)\\gestureType"] else { continue }
                    let mods = indices(kv, prefix: base + "gestures\\\(g)\\gestureModifiers\\")
                    if mods.isEmpty {       // gesture listed without an action = pass the touch through to the app
                        for app in (apps.isEmpty ? ["___global___"] : apps) {
                            rules.append(CommanderRule(gesture: gesture, action: "none", appId: app == "___global___" ? nil : app, role: role))
                        }
                        continue
                    }
                    for m in mods {
                        let mb = base + "gestures\\\(g)\\gestureModifiers\\\(m)\\"
                        guard let action = kv[mb + "actionType"] else { continue }
                        var params: [String: String] = [:]
                        for (k, v) in kv where k.hasPrefix(mb + "actionSettings\\") && !k.hasSuffix("__type") {
                            params[String(k.dropFirst((mb + "actionSettings\\").count))] = v
                        }
                        let mod = (kv[mb + "modifierType"] ?? "").lowercased()
                        for app in (apps.isEmpty ? ["___global___"] : apps) {
                            var r = CommanderRule(gesture: gesture, action: action, params: params.isEmpty ? nil : params,
                                                  appId: app == "___global___" ? nil : app, role: role)
                            if !mod.isEmpty { r.modifiers = mod.split(separator: "+").map(String.init) }
                            rules.append(r)
                        }
                    }
                }
            }
        }
        let info = sections["General"]?["shortDescription"] ?? ""
        return Result(rules: rules, skipped: skipped, summary: "\(rules.count) rules\(skipped > 0 ? ", \(skipped) skipped (recorded UI elements)" : "") \(info)")
    }

    /// Distinct integer indices that follow `prefix` in the keys.
    private static func indices(_ kv: [String: String], prefix: String) -> [Int] {
        var out = Set<Int>()
        for k in kv.keys where k.hasPrefix(prefix) {
            let rest = k.dropFirst(prefix.count)
            if let n = rest.prefix(while: \.isNumber).description.nilIfEmpty.flatMap(Int.init) { out.insert(n) }
        }
        return out.sorted()
    }
}
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

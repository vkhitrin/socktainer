import Foundation

enum NetworkPresentationUtility {
    static func normalizedIPAMOptions(_ object: [String: Any]) -> [String: Any] {
        var object = object
        if var ipam = object["IPAM"] as? [String: Any], ipam["Options"] == nil {
            ipam["Options"] = NSNull()
            object["IPAM"] = ipam
        }
        return object
    }

    static func normalizedIPAMOptions(_ objects: [[String: Any]]) -> [[String: Any]] {
        objects.map(normalizedIPAMOptions)
    }
}

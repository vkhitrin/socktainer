enum ContainerLabelUtility {
    static func boolValue(_ value: String?) -> Bool? {
        guard let value else {
            return nil
        }

        switch value.lowercased() {
        case "true", "1", "yes", "on":
            return true
        case "false", "0", "no", "off":
            return false
        default:
            return nil
        }
    }
}

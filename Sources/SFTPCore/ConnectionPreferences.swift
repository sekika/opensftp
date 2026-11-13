import Foundation

public struct ConnectionPreferences: Sendable, Equatable {
    public var rsyncExtendedAttributes: Bool
    public var connectTimeout: Int
    public var serverAliveInterval: Int
    public var serverAliveCountMax: Int
    public var strictHostKeyChecking: String
    public var rsyncCompression: Bool
    public var extraOptions: String

    public static let `default` = ConnectionPreferences(
        rsyncExtendedAttributes: false,
        connectTimeout: 15,
        serverAliveInterval: 15,
        serverAliveCountMax: 3,
        strictHostKeyChecking: "yes",
        rsyncCompression: true,
        extraOptions: ""
    )

    public init(
        rsyncExtendedAttributes: Bool = false,
        connectTimeout: Int = 15,
        serverAliveInterval: Int = 15,
        serverAliveCountMax: Int = 3,
        strictHostKeyChecking: String = "yes",
        rsyncCompression: Bool = true,
        extraOptions: String = ""
    ) {
        self.rsyncExtendedAttributes = rsyncExtendedAttributes
        self.connectTimeout = connectTimeout
        self.serverAliveInterval = serverAliveInterval
        self.serverAliveCountMax = serverAliveCountMax
        self.strictHostKeyChecking = strictHostKeyChecking
        self.rsyncCompression = rsyncCompression
        self.extraOptions = extraOptions
    }

    public init(defaults: UserDefaults) {
        self.rsyncExtendedAttributes = defaults.bool(forKey: "rsyncExtendedAttributes")
        let timeout = defaults.integer(forKey: "sshConnectTimeout")
        self.connectTimeout = timeout > 0 ? timeout : 15
        let interval = defaults.object(forKey: "sshServerAliveInterval") as? Int
        self.serverAliveInterval = interval != nil ? interval! : 15
        let countMax = defaults.integer(forKey: "sshServerAliveCountMax")
        self.serverAliveCountMax = countMax > 0 ? countMax : 3
        self.strictHostKeyChecking = defaults.string(forKey: "sshStrictHostKeyChecking") ?? "yes"
        self.rsyncCompression = defaults.object(forKey: "rsyncCompression") as? Bool ?? true
        self.extraOptions = defaults.string(forKey: "sshExtraOptions") ?? ""
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(rsyncExtendedAttributes, forKey: "rsyncExtendedAttributes")
        defaults.set(connectTimeout, forKey: "sshConnectTimeout")
        defaults.set(serverAliveInterval, forKey: "sshServerAliveInterval")
        defaults.set(serverAliveCountMax, forKey: "sshServerAliveCountMax")
        defaults.set(strictHostKeyChecking, forKey: "sshStrictHostKeyChecking")
        defaults.set(rsyncCompression, forKey: "rsyncCompression")
        defaults.set(extraOptions, forKey: "sshExtraOptions")
    }

    public static var standard: ConnectionPreferences {
        ConnectionPreferences(defaults: .standard)
    }
}

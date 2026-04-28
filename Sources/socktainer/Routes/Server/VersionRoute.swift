import Vapor

struct VersionRoute: RouteCollection {
    private static func components() -> [SystemVersionComponentsInner] {
        let engineVersion = getBuildVersion()
        let apiVersion = getDockerEngineApiMaxVersion()
        let minApiVersion = getDockerEngineApiMinVersion()
        let kernelVersion = getKernel()

        return [
            SystemVersionComponentsInner(
                name: "Engine",
                version: engineVersion,
                details: .dictionary([
                    "GitCommit": .string(getBuildGitCommit()),
                    "ApiVersion": .string(apiVersion),
                    "MinAPIVersion": .string(minApiVersion),
                    "Os": .string("linux"),
                    "Arch": .string(currentPlatform().architecture),
                    "BuildTime": .string(getBuildTime()),
                    "KernelVersion": .string(kernelVersion),
                    "GoVersion": .string(""),
                    "Module": .string(""),
                    "ModuleVersion": .string(""),
                    "Experimental": .string("false"),
                ])
            ),
            SystemVersionComponentsInner(
                name: "apple-container",
                version: getAppleContainerVersion(),
                details: nil
            ),
        ]
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/version", use: VersionRoute.handler)
    }

    static func handler(_ req: Request) async throws -> SystemVersion {
        let kernelVersion = getKernel()
        return SystemVersion(
            platform: SystemVersionPlatform(name: "socktainer"),
            components: components(),
            version: getBuildVersion(),
            apiVersion: getDockerEngineApiMaxVersion(),
            minAPIVersion: getDockerEngineApiMinVersion(),
            gitCommit: getBuildGitCommit(),
            goVersion: "",
            os: "linux",
            arch: currentPlatform().architecture,
            kernelVersion: kernelVersion,
            // Docker's experimental flags describe daemon feature mode, not general project maturity.
            experimental: false,
            buildTime: getBuildTime()
        )
    }
}

import Vapor

enum ContainerMutationRouteUtility {
    static func abort(
        for error: any Error,
        containerID: String,
        operation: String,
        treatAnyClientErrorAsNotFound: Bool = false,
        notRunningReason: String? = nil
    ) -> Abort {
        if let abort = error as? Abort {
            return abort
        }
        if let abort = error as? AbortError {
            return Abort(abort.status, reason: abort.reason)
        }
        if treatAnyClientErrorAsNotFound, error is ClientContainerError {
            return ContainerEventUtility.notFoundAbort(containerID: containerID)
        }
        if case .notFound = (error as? ClientContainerError) {
            return ContainerEventUtility.notFoundAbort(containerID: containerID)
        }
        if case .notRunning = (error as? ClientContainerError), let notRunningReason {
            return Abort(.conflict, reason: notRunningReason)
        }
        return Abort(.internalServerError, reason: "Failed to \(operation) container: \(error)")
    }
}

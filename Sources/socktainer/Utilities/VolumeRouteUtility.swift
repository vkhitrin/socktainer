import ContainerResource
import ContainerizationError
import Vapor

enum VolumeRouteUtility {
    static func requiredVolumeName(from request: Request, parameter: String = "name", missingReason: String) throws -> String {
        guard let name = request.parameters.get(parameter) else {
            throw Abort(.badRequest, reason: missingReason)
        }
        return name
    }

    static func mapInspectError(_ error: Error, volumeName: String) -> Error {
        if let abort = error as? AbortError {
            return abort
        }
        if let error = error as? VolumeError {
            switch error {
            case .volumeNotFound:
                return Abort(.notFound, reason: error.localizedDescription)
            default:
                return Abort(.internalServerError, reason: "Failed to inspect volume: \(error.localizedDescription)")
            }
        }
        if let error = error as? ContainerizationError,
            error.code == .invalidArgument,
            error.message.localizedCaseInsensitiveContains("not found")
        {
            return Abort(.notFound, reason: "No such volume: \(volumeName)")
        }
        return Abort(.internalServerError, reason: "Failed to inspect volume: \(error)")
    }

    static func mapDeleteError(_ error: Error) -> Error {
        if let abort = error as? AbortError {
            return abort
        }
        if let error = error as? VolumeError {
            switch error {
            case .volumeNotFound:
                return Abort(.notFound, reason: error.localizedDescription)
            case .volumeInUse:
                return Abort(.conflict, reason: error.localizedDescription)
            default:
                return Abort(.internalServerError, reason: "Failed to delete volume: \(error.localizedDescription)")
            }
        }
        return Abort(.internalServerError, reason: "Failed to delete volume: \(error)")
    }
}

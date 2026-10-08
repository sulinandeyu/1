import Foundation

enum CameraState: Equatable {
    case idle
    case checkingPermission
    case permissionDenied
    case configuring
    case ready
    case capturing
    case failed(String)

    var message: String? {
        switch self {
        case .permissionDenied:
            return "需要相机权限才能拍照。"
        case .failed(let message):
            return message
        default:
            return nil
        }
    }
}


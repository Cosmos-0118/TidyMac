import Foundation

func isPermissionError(_ error: Error) -> Bool {
    let nsError = error as NSError

    if nsError.domain == NSCocoaErrorDomain {
        let codes: Set<Int> = [
            NSFileReadNoPermissionError,
            NSFileWriteNoPermissionError,
            NSFileWriteVolumeReadOnlyError
        ]
        if codes.contains(nsError.code) {
            return true
        }
    }

    if nsError.domain == NSPOSIXErrorDomain,
       let code = POSIXErrorCode(rawValue: Int32(nsError.code)) {
        if code == .EACCES || code == .EPERM {
            return true
        }
    }

    return false
}

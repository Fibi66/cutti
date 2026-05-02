import Darwin
import Foundation

struct RuntimeArchitecture: Equatable, Sendable {
    let machineIdentifier: String
    let isTranslated: Bool

    var isNativeAppleSilicon: Bool {
        machineIdentifier == "arm64" && !isTranslated
    }

    var warningMessage: String? {
        guard !isNativeAppleSilicon else { return nil }
        return "Cutti expects native Apple Silicon. Current runtime is not native arm64."
    }

    static func current(
        machineIdentifier: () -> String = { readMachineIdentifier() },
        isTranslated: () -> Bool = { readTranslatedFlag() }
    ) -> RuntimeArchitecture {
        RuntimeArchitecture(
            machineIdentifier: machineIdentifier(),
            isTranslated: isTranslated()
        )
    }

    private static func readMachineIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(cString: buffer)
    }

    private static func readTranslatedFlag() -> Bool {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0)
        // A non-zero return means the key is absent (native Intel or unsupported),
        // which is not a translated (Rosetta) process.
        guard result == 0 else { return false }
        return translated == 1
    }
}

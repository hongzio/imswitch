import Foundation

private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

/// Stderr only — `brew services` routes it to the formula's error_log_path.
/// Kept deliberately quiet: CmdlineEnter fires a lot, so per-request logging
/// would grow the file fast.
func log(_ message: String) {
    let line = "[\(logFormatter.string(from: Date()))] imswitch: \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

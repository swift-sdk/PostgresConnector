import Foundation
import Logging
import Loggers

/// Forwards postgres-nio's background log (connections closing, keepalives
/// failing, reconnect attempts) at warning and above to the service's
/// `StandardLogger`, prefixed with the database id. Metadata that could carry
/// a query or its binds is dropped.
struct PostgresStandardLogHandler: LogHandler {
    let database: String
    let logger: StandardLogger

    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .warning

    subscript(
        metadataKey key: String
    ) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        event: LogEvent
    ) {
        let merged = metadata.merging(event.metadata ?? [:]) { $1 }
        let fields = merged
            .filter { key, _ in
                !key.contains("query") && !key.contains("bind")
            }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        let line = "postgres \(database): \(event.message)\(fields.isEmpty ? "" : " \(fields)")"

        switch event.level {
        case .critical:
            logger.critical(line)
        case .error:
            logger.error(line)
        default:
            logger.warn(line)
        }
    }

    static func logger(
        database: String,
        logger: StandardLogger?
    ) -> Logging.Logger {
        Logging.Logger(label: "postgres-connector.\(database)") { _ in
            guard let logger else {
                return SwiftLogNoOpLogHandler()
            }
            return PostgresStandardLogHandler(database: database, logger: logger)
        }
    }
}

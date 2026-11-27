import Errors
import Foundation
import PostgresNIO

public enum PostgresConnectorError:
    Error,
    Sendable,
    SemanticError,
    ErrorNamespaced,
    ErrorDispositionProviding
{
    case duplicateDatabaseIdentifier(String)
    case databaseNotRegistered(String)

    /// Declared, but could not be configured when the connector was created.
    case databaseUnavailable(id: String, reason: String)

    /// One or more required databases could not be configured; the connector
    /// was not created. Each entry is `id: reason`.
    case requiredDatabasesUnavailable([String])

    case healthProbeTimedOut(id: String, seconds: Double)

    /// No connection to the database could be obtained within the acquire timeout.
    case connectionUnavailable(id: String, seconds: Double)

    /// A query failed, on the connection or on the server.
    case queryFailed(id: String, failure: PostgresQueryFailure)

    public static let errorNamespace = "postgres.connector"

    public var errorCode: String {
        switch self {
        case .duplicateDatabaseIdentifier: return "duplicate_database_identifier"
        case .databaseNotRegistered: return "database_not_registered"
        case .databaseUnavailable: return "database_unavailable"
        case .requiredDatabasesUnavailable: return "required_databases_unavailable"
        case .healthProbeTimedOut: return "health_probe_timed_out"
        case .connectionUnavailable: return "connection_unavailable"
        case .queryFailed: return "query_failed"
        }
    }

    public var errorPresentation: ErrorPresentation {
        switch self {
        case .duplicateDatabaseIdentifier(let id):
            return .init(message: "Duplicate Postgres database id registered: \(id)")
        case .databaseNotRegistered(let id):
            return .init(message: "No Postgres database registered for id: \(id)")
        case .databaseUnavailable(let id, let reason):
            return .init(message: "Postgres database '\(id)' is unavailable: \(reason)")
        case .requiredDatabasesUnavailable(let entries):
            return .init(message: "Required Postgres databases could not be configured: \(entries.joined(separator: "; "))")
        case .healthProbeTimedOut(let id, let seconds):
            return .init(message: "Postgres database '\(id)' did not answer within \(seconds)s")
        case .connectionUnavailable(let id, let seconds):
            return .init(message: "No connection to Postgres database '\(id)' within \(seconds)s")
        case .queryFailed(let id, let failure):
            return .init(message: "Postgres query on '\(id)' failed: \(failure.summary)")
        }
    }

    public var errorDisposition: ErrorDisposition? {
        switch self {
        case .duplicateDatabaseIdentifier, .databaseNotRegistered:
            return .permanent
        case .databaseUnavailable, .requiredDatabasesUnavailable:
            return .requires_configuration
        case .healthProbeTimedOut, .connectionUnavailable:
            return .transient
        case .queryFailed(_, let failure):
            return failure.disposition
        }
    }

    /// The server's own message can quote input values, so it stays a
    /// diagnostic field marked potentially sensitive, never in the message.
    public var errorDiagnosticFields: [ErrorDiagnosticField] {
        guard case .queryFailed(_, let failure) = self,
              let serverMessage = failure.serverMessage
        else {
            return []
        }
        return [
            .init(
                key: "server_message",
                value: .string(serverMessage),
                sensitivity: .potentially_sensitive
            ),
        ]
    }
}

/// What can be said about a failed query without its text, its binds or
/// the server's message: postgres-nio's code, the SQLSTATE, the object it
/// concerned and the underlying transport error.
public struct PostgresQueryFailure: Sendable, Equatable {
    public let code: String
    public let sqlState: String?
    public let constraint: String?
    public let table: String?
    public let column: String?
    public let underlying: String?
    public let serverMessage: String?

    public init(
        _ error: any Error
    ) {
        guard let psql = error as? PSQLError else {
            self.code = "transport"
            self.sqlState = nil
            self.constraint = nil
            self.table = nil
            self.column = nil
            self.underlying = String(describing: error)
            self.serverMessage = nil
            return
        }

        self.code = psql.code.description
        self.sqlState = psql.serverInfo?[.sqlState]
        self.constraint = psql.serverInfo?[.constraintName]
        self.table = psql.serverInfo?[.tableName]
        self.column = psql.serverInfo?[.columnName]
        self.underlying = psql.underlying.map { String(describing: $0) }
        self.serverMessage = psql.serverInfo?[.message]
    }

    public var summary: String {
        var parts = [code]
        if let sqlState { parts.append("sqlstate=\(sqlState)") }
        if let table { parts.append("table=\(table)") }
        if let column { parts.append("column=\(column)") }
        if let constraint { parts.append("constraint=\(constraint)") }
        if let underlying { parts.append("underlying=\(underlying)") }
        return parts.joined(separator: " ")
    }

    /// Transport and closed-connection failures and SQLSTATE classes 08 (connection), 40
    /// (rollback: serialization, deadlock), 53 (resources) and 57
    /// (operator intervention) are transient; 22 and 23 (data, constraints)
    /// are the input's fault; 28 (authorization) is configuration.
    public var disposition: ErrorDisposition? {
        guard let sqlState else {
            switch code {
            case "transport", "connectionError", "serverClosedConnection", "clientClosedConnection", "uncleanShutdown":
                return .transient
            default:
                return nil
            }
        }
        switch sqlState.prefix(2) {
        case "08", "40", "53", "57": return .transient
        case "22", "23": return .invalid_input
        case "28": return .requires_configuration
        case "42": return .permanent
        default: return nil
        }
    }
}

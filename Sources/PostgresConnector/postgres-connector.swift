import Foundation
import Loggers
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import PostgresNIO
import PSQL

/// One `PostgresClient` pool per declared database. Idle connections run a
/// keepalive query and are closed after the idle timeout (`PostgresPoolOptions`),
/// so a connection a firewall has silently dropped is found by the pool rather
/// than handed to a query.
public actor PostgresConnector {
    private let eventLoopGroup: any EventLoopGroup
    private let ownsEventLoopGroup: Bool
    private let clients: [PostgresDatabaseIdentifier: PostgresClient]
    private let states: [PostgresDatabaseState]
    private let options: PostgresPoolOptions
    private let runTask: Task<Void, Never>

    /// Every database is required: any configuration failure throws, as before.
    public init(
        databases: [PostgresDatabase],
        eventLoopGroup: any EventLoopGroup,
        pool options: PostgresPoolOptions = .init(),
        logger: StandardLogger? = nil
    ) throws {
        try self.init(
            declarations: databases.map { PostgresDatabaseDeclaration($0) },
            eventLoopGroup: eventLoopGroup,
            pool: options,
            logger: logger
        )
    }

    /// Every database is required: any configuration failure throws, as before.
    public init(
        databases: [PostgresDatabase],
        threadCount: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        pool options: PostgresPoolOptions = .init(),
        logger: StandardLogger? = nil
    ) throws {
        try self.init(
            declarations: databases.map { PostgresDatabaseDeclaration($0) },
            threadCount: threadCount,
            pool: options,
            logger: logger
        )
    }

    /// Configures each declaration independently. Optional databases that
    /// cannot be configured are recorded as unavailable; the initializer throws
    /// only when a required one fails (or an id is declared twice).
    public init(
        declarations: [PostgresDatabaseDeclaration],
        eventLoopGroup: any EventLoopGroup,
        pool options: PostgresPoolOptions = .init(),
        logger: StandardLogger? = nil
    ) throws {
        let built = try Self.build(
            declarations: declarations,
            eventLoopGroup: eventLoopGroup,
            options: options,
            logger: logger
        )
        self.eventLoopGroup = eventLoopGroup
        self.ownsEventLoopGroup = false
        self.clients = built.clients
        self.states = built.states
        self.options = options
        self.runTask = Self.start(built.clients)
    }

    /// Configures each declaration independently. Optional databases that
    /// cannot be configured are recorded as unavailable; the initializer throws
    /// only when a required one fails (or an id is declared twice).
    public init(
        declarations: [PostgresDatabaseDeclaration],
        threadCount: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        pool options: PostgresPoolOptions = .init(),
        logger: StandardLogger? = nil
    ) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: threadCount)

        do {
            let built = try Self.build(
                declarations: declarations,
                eventLoopGroup: group,
                options: options,
                logger: logger
            )
            self.eventLoopGroup = group
            self.ownsEventLoopGroup = true
            self.clients = built.clients
            self.states = built.states
            self.options = options
            self.runTask = Self.start(built.clients)
        } catch {
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    public func rows(
        for query: PostgresPreparedQuery,
        on database: PostgresDatabaseIdentifier
    ) async throws -> [PostgresRow] {
        let id = database.rawValue

        return try await withConnection(on: database) { connection in
            try await Self.reporting(id) {
                try await connection.query(query.sql, query.binds).get().rows
            }
        }
    }

    public func rows(
        for renderedSQL: PSQL.RenderedSQL,
        on database: PostgresDatabaseIdentifier
    ) async throws -> [PostgresRow] {
        return try await rows(
            for: .init(renderedSQL),
            on: database
        )
    }

    public func rows(
        sql: String,
        binds: [PostgresData] = [],
        on database: PostgresDatabaseIdentifier
    ) async throws -> [PostgresRow] {
        return try await rows(
            for: .init(sql: sql, binds: binds),
            on: database
        )
    }

    public func run(
        _ query: PostgresPreparedQuery,
        on database: PostgresDatabaseIdentifier
    ) async throws {
        let id = database.rawValue

        try await withConnection(on: database) { connection in
            try await Self.reporting(id) {
                _ = try await connection.query(query.sql, query.binds).get()
            }
        }
    }

    public func run(
        _ renderedSQL: PSQL.RenderedSQL,
        on database: PostgresDatabaseIdentifier
    ) async throws {
        try await run(
            .init(renderedSQL),
            on: database
        )
    }

    public func run(
        sql: String,
        binds: [PostgresData] = [],
        on database: PostgresDatabaseIdentifier
    ) async throws {
        try await run(
            .init(sql: sql, binds: binds),
            on: database
        )
    }

    public func transaction<Result: Sendable>(
        on database: PostgresDatabaseIdentifier,
        options: PostgresTransactionOptions = .init(),
        _ operation: @escaping @Sendable (
            PostgresTransaction
        ) async throws -> Result
    ) async throws -> Result {
        let id = database.rawValue

        return try await withConnection(on: database) { connection in
            let transaction = PostgresTransaction(
                connection: connection,
                database: id
            )

            do {
                try Task.checkCancellation()

                try await transaction.begin(
                    options: options
                )
            } catch {
                await transaction.close()

                throw error
            }

            do {
                let result = try await operation(
                    transaction
                )

                try Task.checkCancellation()

                try await transaction.commit()

                await transaction.close()

                return result
            } catch {
                let operationError = error

                do {
                    try await transaction.rollback()
                } catch {
                    let rollbackError = error

                    await transaction.close()

                    throw PostgresTransactionError
                        .rollbackFailed(
                            operation: operationError.localizedDescription,
                            rollback: rollbackError.localizedDescription
                        )
                }

                await transaction.close()

                throw operationError
            }
        }
    }

    /// Every declared database and whether it can be queried, in declaration order.
    public func databaseStates() -> [PostgresDatabaseState] {
        states
    }

    /// Probes every declared database with `SELECT 1`. Never throws: each
    /// database reports `ready`, `unreachable` (with the error) or `unconfigured`.
    public func health(
        timeoutSeconds: Double = 3
    ) async -> [PostgresDatabaseHealth] {
        var results: [PostgresDatabaseHealth] = []

        for state in states {
            let required = state.requirement == .required

            guard case .configured = state.status else {
                if case .unavailable(let reason) = state.status {
                    results.append(
                        PostgresDatabaseHealth(
                            id: state.id.rawValue,
                            required: required,
                            state: .unconfigured,
                            latencyMilliseconds: nil,
                            detail: reason
                        )
                    )
                }
                continue
            }

            let started = DispatchTime.now()

            do {
                try await probe(state.id, timeoutSeconds: timeoutSeconds)
                let elapsed = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds

                results.append(
                    PostgresDatabaseHealth(
                        id: state.id.rawValue,
                        required: required,
                        state: .ready,
                        latencyMilliseconds: Int(elapsed / 1_000_000),
                        detail: nil
                    )
                )
            } catch {
                results.append(
                    PostgresDatabaseHealth(
                        id: state.id.rawValue,
                        required: required,
                        state: .unreachable,
                        latencyMilliseconds: nil,
                        detail: error.localizedDescription
                    )
                )
            }
        }

        return results
    }

    private func probe(
        _ database: PostgresDatabaseIdentifier,
        timeoutSeconds: Double
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await self.rows(sql: "SELECT 1", on: database)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw PostgresConnectorError.healthProbeTimedOut(id: database.rawValue, seconds: timeoutSeconds)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    public func registeredDatabaseIdentifiers() -> [PostgresDatabaseIdentifier] {
        return clients.keys.sorted {
            $0.rawValue < $1.rawValue
        }
    }

    /// Closes every pool's connections, then the event loops if the connector created them.
    public func shutdown() async {
        runTask.cancel()
        await runTask.value

        if ownsEventLoopGroup {
            try? await eventLoopGroup.shutdownGracefully()
        }
    }

    private func client(
        for database: PostgresDatabaseIdentifier
    ) throws -> PostgresClient {
        guard let client = clients[database] else {
            if let state = states.first(where: { $0.id == database }),
               case .unavailable(let reason) = state.status
            {
                throw PostgresConnectorError.databaseUnavailable(id: database.rawValue, reason: reason)
            }
            throw PostgresConnectorError.databaseNotRegistered(database.rawValue)
        }
        return client
    }

    /// Leases a connection, waiting at most `acquireTimeout` for one. The
    /// timeout covers only the wait: once `body` has its connection it runs to
    /// completion, so a write is never reported failed after it ran.
    private func withConnection<Result: Sendable>(
        on database: PostgresDatabaseIdentifier,
        _ body: @escaping @Sendable (PostgresConnection) async throws -> Result
    ) async throws -> Result {
        let client = try self.client(for: database)
        let id = database.rawValue
        let timeout = options.acquireTimeout
        let lease = NIOLockedValueBox(LeaseState.waiting)

        return try await withThrowingTaskGroup(of: Result?.self) { group in
            group.addTask {
                do {
                    return try await client.withConnection { connection in
                        let claimed = lease.withLockedValue { state in
                            guard state == .waiting else { return false }
                            state = .leased
                            return true
                        }
                        guard claimed else {
                            throw CancellationError()
                        }
                        return try await body(connection)
                    }
                } catch where lease.withLockedValue({ $0 }) != .leased {
                    if error is CancellationError || error is PostgresConnectorError {
                        throw error
                    }
                    throw PostgresConnectorError.queryFailed(id: id, failure: .init(error))
                }
            }

            group.addTask {
                try await Task.sleep(for: timeout)

                let expired = lease.withLockedValue { state in
                    guard state == .waiting else { return false }
                    state = .timedOut
                    return true
                }
                guard expired else {
                    return nil
                }
                throw PostgresConnectorError.connectionUnavailable(id: id, seconds: Self.seconds(timeout))
            }

            defer { group.cancelAll() }

            while let value = try await group.next() {
                if let value {
                    return value
                }
            }
            throw CancellationError()
        }
    }

    /// Rethrows a query's failure as `PostgresConnectorError.queryFailed`,
    /// whose description is safe to log (see `PostgresQueryFailure`).
    static func reporting<Result>(
        _ database: String,
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> Result
    ) async throws -> Result {
        do {
            return try await operation()
        } catch let error as PostgresConnectorError {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch {
            throw PostgresConnectorError.queryFailed(id: database, failure: .init(error))
        }
    }

    private static func seconds(
        _ duration: Duration
    ) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func start(
        _ clients: [PostgresDatabaseIdentifier: PostgresClient]
    ) -> Task<Void, Never> {
        let clients = Array(clients.values)

        return Task {
            await withTaskGroup(of: Void.self) { group in
                for client in clients {
                    group.addTask {
                        await client.run()
                    }
                }
            }
        }
    }

    private static func build(
        declarations: [PostgresDatabaseDeclaration],
        eventLoopGroup: any EventLoopGroup,
        options: PostgresPoolOptions,
        logger: StandardLogger?
    ) throws -> (
        clients: [PostgresDatabaseIdentifier: PostgresClient],
        states: [PostgresDatabaseState]
    ) {
        var seen: Set<PostgresDatabaseIdentifier> = []
        for declaration in declarations {
            guard seen.insert(declaration.id).inserted else {
                throw PostgresConnectorError.duplicateDatabaseIdentifier(declaration.id.rawValue)
            }
        }

        var clients: [PostgresDatabaseIdentifier: PostgresClient] = [:]
        var states: [PostgresDatabaseState] = []
        var missingRequired: [String] = []

        for declaration in declarations {
            do {
                let database = try declaration.resolve()
                guard database.id == declaration.id else {
                    throw PostgresConnectorError.databaseNotRegistered(
                        "declaration '\(declaration.id.rawValue)' resolved to '\(database.id.rawValue)'"
                    )
                }

                clients[declaration.id] = PostgresClient(
                    configuration: try database.make.client_configuration(options: options),
                    eventLoopGroup: eventLoopGroup,
                    backgroundLogger: PostgresStandardLogHandler.logger(
                        database: declaration.id.rawValue,
                        logger: logger
                    )
                )
                states.append(
                    PostgresDatabaseState(id: declaration.id, requirement: declaration.requirement, status: .configured)
                )
            } catch {
                let reason = error.localizedDescription
                states.append(
                    PostgresDatabaseState(id: declaration.id, requirement: declaration.requirement, status: .unavailable(reason: reason))
                )
                if declaration.requirement == .required {
                    missingRequired.append("\(declaration.id.rawValue): \(reason)")
                }
            }
        }

        // Clients that never ran hold no connections; nothing to close.
        guard missingRequired.isEmpty else {
            throw PostgresConnectorError.requiredDatabasesUnavailable(missingRequired)
        }

        return (clients, states)
    }
}

private enum LeaseState: Sendable, Equatable {
    case waiting
    case leased
    case timedOut
}

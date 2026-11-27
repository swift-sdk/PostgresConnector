import Foundation

/// How each database's connection pool behaves. One pool per declared database.
public struct PostgresPoolOptions: Sendable, Equatable {
    /// Open connections per database, at most.
    public var maximumConnections: Int

    /// How long a query waits for a connection before it fails with
    /// `PostgresConnectorError.connectionUnavailable`. Bounds the wait while the
    /// server is unreachable; a query that already has a connection is never cut off.
    public var acquireTimeout: Duration

    /// How often an idle connection runs `SELECT 1`. Keeps it alive in the
    /// connection tracking of firewalls between us and the server, and finds a dead
    /// one before a query does. `nil` disables it.
    public var keepAliveFrequency: Duration?

    /// Idle connections above the minimum are closed after this long.
    public var idleTimeout: Duration

    public var connectTimeout: Duration

    public init(
        maximumConnections: Int = 4,
        acquireTimeout: Duration = .seconds(10),
        keepAliveFrequency: Duration? = .seconds(30),
        idleTimeout: Duration = .seconds(60),
        connectTimeout: Duration = .seconds(10)
    ) {
        self.maximumConnections = maximumConnections
        self.acquireTimeout = acquireTimeout
        self.keepAliveFrequency = keepAliveFrequency
        self.idleTimeout = idleTimeout
        self.connectTimeout = connectTimeout
    }
}

import Foundation
import Milieu
import NIOSSL
import PostgresNIO

public struct PostgresDatabase: Sendable {
    public let id: PostgresDatabaseIdentifier
    public let host: String
    public let port: Int
    public let username: String
    public let password: String
    public let database: String
    public let tls: TLS

    public init(
        id: PostgresDatabaseIdentifier,
        host: String,
        port: Int = 5432,
        username: String,
        password: String,
        database: String,
        tls: TLS
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.tls = tls
    }

    public init<HostKey, UserKey, PasswordKey, CAKey>(
        id: PostgresDatabaseIdentifier,
        host: HostKey,
        port: Int = 5432,
        username: UserKey,
        password: PasswordKey,
        database: String,
        caCert: CAKey,
        verification: CertificateVerification = .noHostnameVerification
    ) throws
        where
        HostKey: EnvironmentExtractable,
        UserKey: EnvironmentExtractable,
        PasswordKey: EnvironmentExtractable,
        CAKey: EnvironmentExtractable
    {
        self.init(
            id: id,
            host: try host.value(),
            port: port,
            username: try username.value(),
            password: try password.value(),
            database: database,
            tls: .requireCAFile(
                try caCert.value(),
                verification: verification
            )
        )
    }

    public var make: FunctionsAPI {
        return .init(postgresdatabase: self)
    }
}

extension PostgresDatabase {
    public struct TLS: Sendable {
        public let caFile: String?
        public let verification: CertificateVerification

        public init(
            caFile: String?,
            verification: CertificateVerification = .noHostnameVerification
        ) {
            self.caFile = caFile
            self.verification = verification
        }

        public static func requireCAFile(
            _ path: String,
            verification: CertificateVerification = .noHostnameVerification
        ) -> Self {
            return .init(
                caFile: path,
                verification: verification
            )
        }

        public static var disabled: Self {
            return .init(caFile: nil)
        }
    }
}

extension PostgresDatabase {
    public struct FunctionsAPI: Sendable {
        public let postgresdatabase: PostgresDatabase
        
        public init(
            postgresdatabase: PostgresDatabase
        ) {
            self.postgresdatabase = postgresdatabase
        }

        /// Loads the CA file once, so a missing or invalid one fails when the
        /// connector is created rather than on the first query.
        public static func tls_configuration(
            caFile: String,
            verification: CertificateVerification
        ) throws -> TLSConfiguration {
            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            tlsConfiguration.certificateVerification = verification
            tlsConfiguration.trustRoots = .file(caFile)

            _ = try NIOSSLContext(configuration: tlsConfiguration)

            return tlsConfiguration
        }

        public func client_configuration(
            options: PostgresPoolOptions
        ) throws -> PostgresClient.Configuration {
            let tls: PostgresClient.Configuration.TLS
            if let caFile = postgresdatabase.tls.caFile {
                tls = .require(
                    try Self.tls_configuration(
                        caFile: caFile,
                        verification: postgresdatabase.tls.verification
                    )
                )
            } else {
                tls = .disable
            }

            var configuration = PostgresClient.Configuration(
                host: postgresdatabase.host,
                port: postgresdatabase.port,
                username: postgresdatabase.username,
                password: postgresdatabase.password,
                database: postgresdatabase.database,
                tls: tls
            )
            configuration.options.maximumConnections = options.maximumConnections
            configuration.options.connectionIdleTimeout = options.idleTimeout
            configuration.options.connectTimeout = options.connectTimeout
            configuration.options.keepAliveBehavior = options.keepAliveFrequency.map {
                .init(frequency: $0)
            }

            return configuration
        }
    }
}

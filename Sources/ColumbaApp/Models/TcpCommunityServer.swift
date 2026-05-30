//
//  TcpCommunityServer.swift
//  ColumbaApp
//
//  Community TCP server directory matching Android Columba.
//  Provides a curated list of public Reticulum transport nodes.
//

import Foundation
import RNSAPI

/// A public Reticulum TCP transport node.
struct TcpCommunityServer: Identifiable {
    let id = UUID()
    let name: String
    let host: String
    let port: UInt16
    let isBootstrap: Bool

    /// Address string in "host:port" format.
    var address: String { "\(host):\(port)" }
}

// MARK: - Server Directory

extension TcpCommunityServer {
    /// Curated list of public Reticulum transport nodes.
    ///
    /// Sourced from Android Columba's `TcpCommunityServer.kt`. Keep this list
    /// in sync with `app/src/main/java/network/columba/app/data/model/TcpCommunityServer.kt`.
    /// Up-to-date community directories: directory.rns.recipes, rmap.world.
    static let servers: [TcpCommunityServer] = [
        // Bootstrap-class servers (well-established, reliable nodes).
        // Reticulum-Swift does not yet support the bootstrap interface mode,
        // so the iOS UI surfaces these alongside other community servers.
        TcpCommunityServer(name: "Beleth RNS Hub", host: "rns.beleth.net", port: 4242, isBootstrap: true),
        TcpCommunityServer(name: "Quad4 TCP Node 1", host: "rns.quad4.io", port: 4242, isBootstrap: true),
        TcpCommunityServer(name: "FireZen", host: "firezen.com", port: 4242, isBootstrap: true),

        // Community servers
        TcpCommunityServer(name: "g00n.cloud Hub", host: "dfw.us.g00n.cloud", port: 6969, isBootstrap: false),
        TcpCommunityServer(name: "noDNS1", host: "202.61.243.41", port: 4965, isBootstrap: false),
        TcpCommunityServer(name: "noDNS2", host: "193.26.158.230", port: 4965, isBootstrap: false),
        TcpCommunityServer(name: "NomadNode SEAsia TCP", host: "rns.jaykayenn.net", port: 4242, isBootstrap: false),
        TcpCommunityServer(name: "0rbit-Net", host: "93.95.227.8", port: 49952, isBootstrap: false),
        TcpCommunityServer(name: "Quad4 TCP Node 2", host: "rns2.quad4.io", port: 4242, isBootstrap: false),
        TcpCommunityServer(name: "SparkN0de", host: "aspark.uber.space", port: 44860, isBootstrap: false),
    ]

    /// Default server for first-time connections.
    static var defaultServer: TcpCommunityServer {
        servers.first(where: { $0.isBootstrap }) ?? servers[0]
    }
}

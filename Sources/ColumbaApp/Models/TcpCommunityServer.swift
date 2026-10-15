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
    ///
    /// Mirrors Android's list verbatim, including order. Android removed
    /// bootstrap-as-default (commit d22ba34aa) and no server is flagged
    /// bootstrap, so every entry here is `isBootstrap: false`. `defaultServer`
    /// therefore resolves to `servers[0]` — matching Android, whose onboarding
    /// default is `TcpCommunityServers.servers.firstOrNull()`.
    static let servers: [TcpCommunityServer] = [
        TcpCommunityServer(name: "rns.kin.earth", host: "rns.kin.earth", port: 4242, isBootstrap: false),
        TcpCommunityServer(name: "rmap.world", host: "rmap.world", port: 4242, isBootstrap: false),
        TcpCommunityServer(name: "RNS Sofia", host: "193.193.182.147", port: 4242, isBootstrap: false),
        TcpCommunityServer(name: "noDNS1", host: "202.61.243.41", port: 4965, isBootstrap: false),
        TcpCommunityServer(name: "noDNS2", host: "193.26.158.230", port: 4965, isBootstrap: false),
        TcpCommunityServer(name: "interloper node", host: "intr.cx", port: 4242, isBootstrap: false),
        TcpCommunityServer(name: "Jon's Node", host: "rns.jlamothe.net", port: 4242, isBootstrap: false),
        TcpCommunityServer(name: "R-Net TCP", host: "istanbul.reserve.network", port: 9034, isBootstrap: false),
        TcpCommunityServer(name: "RNS bnZ-NODE01", host: "node01.rns.bnz.se", port: 4242, isBootstrap: false),
        TcpCommunityServer(name: "RNS_Transport_US-East", host: "45.77.109.86", port: 4965, isBootstrap: false),
        TcpCommunityServer(name: "SparkN0de", host: "aspark.uber.space", port: 44860, isBootstrap: false),
        TcpCommunityServer(name: "Beleth RNS Hub", host: "rns.beleth.net", port: 4242, isBootstrap: false),
        TcpCommunityServer(name: "g00n.cloud Hub", host: "dfw.us.g00n.cloud", port: 6969, isBootstrap: false),
    ]

    /// Default server for first-time connections.
    ///
    /// Matches Android's `TcpCommunityServers.servers.firstOrNull()`: with no
    /// server flagged bootstrap, this is simply the first entry.
    static var defaultServer: TcpCommunityServer {
        servers.first(where: { $0.isBootstrap }) ?? servers[0]
    }
}

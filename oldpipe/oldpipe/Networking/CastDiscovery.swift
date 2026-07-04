import Foundation

// MARK: - CastDiscovery
// Finds Chromecast devices on the LAN via mDNS/Bonjour (`_googlecast._tcp.`).
// NSNetServiceBrowser is iOS 2+ so it's safe on iOS 6. Resolves each service to
// an IPv4 address + port (8009) which CastSession then TLS-connects to.

struct CastDevice {
    let name: String
    let host: String   // dotted IPv4
    let port: Int
}

class CastDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {

    // Called on the main thread whenever the device list changes.
    var onUpdate: (([CastDevice]) -> Void)?

    private let browser = NetServiceBrowser()
    private var resolving = [NetService]()   // retain while resolving
    private var devices = [CastDevice]()

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        devices.removeAll()
        resolving.removeAll()
        browser.searchForServices(ofType: "_googlecast._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        resolving.removeAll()
    }

    // MARK: NetServiceBrowserDelegate

    func netServiceBrowser(_ b: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(_ b: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        devices.removeAll { $0.name == service.name }
        resolving.removeAll { $0 == service }
        onUpdate?(devices)
    }

    // MARK: NetServiceDelegate

    func netServiceDidResolveAddress(_ service: NetService) {
        guard let addrs = service.addresses else { return }
        for data in addrs {
            if let ip = CastDiscovery.ipv4String(from: data) {
                // Chromecast control port is always 8009 (the Bonjour port is the HTTP one).
                let dev = CastDevice(name: friendlyName(service), host: ip, port: 8009)
                if !devices.contains(where: { $0.name == dev.name }) {
                    devices.append(dev)
                    onUpdate?(devices)
                }
                break
            }
        }
        resolving.removeAll { $0 == service }
    }

    func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 == service }
    }

    // MARK: Helpers

    // Prefer the TXT "fn" (friendly name) record; fall back to the service name.
    private func friendlyName(_ service: NetService) -> String {
        if let txt = service.txtRecordData() {
            let dict = NetService.dictionary(fromTXTRecord: txt)
            if let fnData = dict["fn"], let fn = String(data: fnData, encoding: .utf8), !fn.isEmpty {
                return fn
            }
        }
        return service.name
    }

    // Extract a dotted IPv4 string from a sockaddr blob. IPv4 only — Chromecast
    // always advertises an A record and inet_ntop keeps us off iOS 7+ APIs.
    private static func ipv4String(from data: Data) -> String? {
        var result: String?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let sa = base.assumingMemoryBound(to: sockaddr.self)
            guard Int32(sa.pointee.sa_family) == AF_INET else { return }
            let sin = base.assumingMemoryBound(to: sockaddr_in.self)
            var addr = sin.pointee.sin_addr
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                result = String(cString: buf)
            }
        }
        return result
    }
}

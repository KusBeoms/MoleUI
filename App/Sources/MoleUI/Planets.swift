import SwiftUI
import SceneKit
import AppKit
import simd

enum PlanetKind: String, CaseIterable {
    case earth, mercury, jupiter, sun, mars
}

struct PlanetMaps {
    let color: CGImage
    let bump: CGImage?
}

// MARK: - 3D noise (sampled on the sphere, so there is no seam and no pole pinching)

private typealias V3 = SIMD3<Float>

@inline(__always) private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) private func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }
@inline(__always) private func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = clamp01((x - a) / (b - a))
    return t * t * (3 - 2 * t)
}
@inline(__always) private func mix(_ a: V3, _ b: V3, _ t: Float) -> V3 { a + (b - a) * clamp01(t) }

private struct Noise3 {
    let seed: UInt32

    @inline(__always) func h(_ x: Int, _ y: Int, _ z: Int) -> Float {
        let a = UInt32(truncatingIfNeeded: x) &* 374_761_393
        let b = UInt32(truncatingIfNeeded: y) &* 668_265_263
        let c = UInt32(truncatingIfNeeded: z) &* 1_103_515_245
        var n = a &+ b &+ c &+ (seed &* 2_246_822_519)
        n = (n ^ (n >> 13)) &* 1_274_126_177
        n ^= n >> 16
        return Float(n & 0xFFFF) / 65535
    }

    func value(_ p: V3) -> Float {
        let f = p.rounded(.down)
        let ix = Int(f.x), iy = Int(f.y), iz = Int(f.z)
        let t0 = p - f
        let t = t0 * t0 * (V3(repeating: 3) - 2 * t0)
        let x00 = lerp(h(ix, iy, iz), h(ix + 1, iy, iz), t.x)
        let x10 = lerp(h(ix, iy + 1, iz), h(ix + 1, iy + 1, iz), t.x)
        let x01 = lerp(h(ix, iy, iz + 1), h(ix + 1, iy, iz + 1), t.x)
        let x11 = lerp(h(ix, iy + 1, iz + 1), h(ix + 1, iy + 1, iz + 1), t.x)
        return lerp(lerp(x00, x10, t.y), lerp(x01, x11, t.y), t.z)
    }

    func fbm(_ p: V3, _ octaves: Int) -> Float {
        var sum: Float = 0, amp: Float = 0.5, norm: Float = 0
        var q = p
        for _ in 0..<octaves {
            sum += amp * value(q)
            norm += amp
            amp *= 0.5
            let r = V3(q.x * 0.8 - q.z * 0.6, q.y, q.x * 0.6 + q.z * 0.8)
            q = r * 2.02 + V3(1.7, 9.2, 3.1)
        }
        return sum / norm
    }

    /// Low-frequency vector offset used to bend coastlines and bands.
    func warp(_ p: V3) -> V3 {
        V3(value(p * 1.3 + V3(5.2, 1.3, 7.7)), value(p * 1.3 + V3(9.1, 3.7, 2.3)), value(p * 1.3 + V3(0.3, 8.8, 4.1))) - V3(repeating: 0.5)
    }
}

// MARK: - Texture generation

enum PlanetTextures {
    private static let width = 4096, height = 2048
    private static let lock = NSLock()
    private static var cache: [PlanetKind: PlanetMaps] = [:]

    private static func cached(_ k: PlanetKind) -> PlanetMaps? {
        lock.lock(); defer { lock.unlock() }
        return cache[k]
    }
    private static func store(_ k: PlanetKind, _ m: PlanetMaps) {
        lock.lock(); cache[k] = m; lock.unlock()
    }

    static func load(_ kind: PlanetKind) async -> PlanetMaps {
        if let c = cached(kind) { return c }
        let maps = await Task.detached(priority: .userInitiated) { make(kind) }.value
        store(kind, maps)
        return maps
    }

    @inline(__always) private static func point(_ x: Int, _ y: Int) -> V3 {
        let lon = (Float(x) + 0.5) / Float(width) * 2 * .pi
        let lat = (0.5 - (Float(y) + 0.5) / Float(height)) * .pi
        let cl = cos(lat)
        return V3(cl * cos(lon), sin(lat), cl * sin(lon))
    }

    private static func make(_ kind: PlanetKind) -> PlanetMaps {
        let w = width, h = height
        let n1 = Noise3(seed: 7), n2 = Noise3(seed: 91), n3 = Noise3(seed: 1337)
        let color = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
        let bump = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h)
        let terrain = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        defer { color.deallocate(); bump.deallocate(); terrain.deallocate() }
        terrain.initialize(repeating: 0.5, count: w * h)
        bump.initialize(repeating: 128, count: w * h)

        @inline(__always) func put(_ i: Int, _ c: V3, _ b: Float) {
            color[i * 4] = UInt8(clamp01(c.x) * 255)
            color[i * 4 + 1] = UInt8(clamp01(c.y) * 255)
            color[i * 4 + 2] = UInt8(clamp01(c.z) * 255)
            color[i * 4 + 3] = 255
            bump[i] = UInt8(clamp01(b) * 255)
        }

        let cratered = kind == .mercury || kind == .mars

        // Pass 1: terrain heights for cratered bodies, final color for the rest.
        DispatchQueue.concurrentPerform(iterations: h) { y in
            for x in 0..<w {
                let p = point(x, y)
                let i = y * w + x
                switch kind {
                case .earth:
                    let (c, b) = earth(p, n1, n2, n3)
                    put(i, c, b)
                case .jupiter:
                    put(i, jupiter(p, n1, n2, n3), 0.5)
                case .sun:
                    put(i, sun(p, n1, n2, n3), 0.5)
                case .mercury:
                    let big = n1.fbm(p * 1.4, 4)
                    let mid = n2.fbm(p * 4.5, 7)
                    terrain[i] = 0.45 + 0.28 * (mid - 0.5) + 0.35 * (big - 0.5)
                case .mars:
                    let t = n1.fbm(p * 2.2 + n1.warp(p) * 0.6, 8)
                    terrain[i] = 0.5 + (t - 0.5) * 0.9
                }
            }
        }

        // Pass 2: craters, serial because they overlap.
        if cratered {
            var rng = SplitMix(seed: kind == .mercury ? 42 : 4242)
            addCraters(terrain, count: kind == .mercury ? 1100 : 260, maxRadius: kind == .mercury ? 0.2 : 0.12,
                       strength: kind == .mercury ? 0.20 : 0.10, rng: &rng)
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    let i = y * w + x
                    let t = terrain[i]
                    if kind == .mercury {
                        let g = clamp01(t * 1.12 - 0.03)
                        put(i, V3(g * 1.03, g, g * 0.95), t)
                    } else {
                        let p = point(x, y)
                        let region = n2.fbm(p * 1.6 + V3(3, 1, 7), 5)
                        let fine = n3.fbm(p * 9, 5)
                        let lat = abs(p.y)
                        var c = mix(V3(0.78, 0.42, 0.24), V3(0.56, 0.26, 0.15), smooth(0.35, 0.65, t))
                        c = mix(c, V3(0.27, 0.14, 0.10), smooth(0.52, 0.66, region) * 0.8)
                        c = mix(c, V3(0.88, 0.62, 0.42), smooth(0.58, 0.8, fine) * 0.35)
                        c *= 0.72 + 0.5 * t
                        c = mix(c, V3(0.95, 0.95, 0.97), smooth(0.86, 0.93, lat + (fine - 0.5) * 0.06))
                        put(i, c, t)
                    }
                }
            }
        }

        let space = CGColorSpaceCreateDeviceRGB()
        let colorCtx = CGContext(data: color, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                 space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colorImage = colorCtx.makeImage()!
        var bumpImage: CGImage?
        if kind == .earth || kind == .mercury || kind == .mars {
            let strength: Float = kind == .earth ? 10 : kind == .mercury ? 60 : 50
            bumpImage = normalMap(from: bump, strength: strength)
        }
        return PlanetMaps(color: colorImage, bump: bumpImage)
    }

    /// Tangent-space normal map from a height field (RGB = xyz * 0.5 + 0.5).
    private static func normalMap(from hgt: UnsafeMutablePointer<UInt8>, strength: Float) -> CGImage? {
        let w = width, h = height
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
        defer { out.deallocate() }
        DispatchQueue.concurrentPerform(iterations: h) { y in
            let lat = (0.5 - (Float(y) + 0.5) / Float(h)) * .pi
            let k = strength * max(cos(lat), 0.15)
            let ym = max(y - 1, 0), yp = min(y + 1, h - 1)
            for x in 0..<w {
                let xm = (x + w - 1) % w, xp = (x + 1) % w
                let dx = (Float(hgt[y * w + xp]) - Float(hgt[y * w + xm])) / 255 * 0.5 * k
                let dy = (Float(hgt[yp * w + x]) - Float(hgt[ym * w + x])) / 255 * 0.5 * strength
                let n = simd_normalize(V3(-dx, dy, 1))
                let i = (y * w + x) * 4
                out[i] = UInt8(clamp01(n.x * 0.5 + 0.5) * 255)
                out[i + 1] = UInt8(clamp01(n.y * 0.5 + 0.5) * 255)
                out[i + 2] = UInt8(clamp01(n.z * 0.5 + 0.5) * 255)
                out[i + 3] = 255
            }
        }
        let ctx = CGContext(data: out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return ctx?.makeImage()
    }

    // MARK: Per-body color models

    private static func earth(_ p: V3, _ n1: Noise3, _ n2: Noise3, _ n3: Noise3) -> (V3, Float) {
        let q = p * 1.35 + n1.warp(p) * 0.5
        let land = clamp01((n1.fbm(q, 9) - 0.5) * 1.9 + 0.5)
        let lat = abs(p.y)
        let coast: Float = 0.575
        var c: V3
        var b: Float
        if land < coast {
            let d = pow(smooth(0.22, coast, land), 1.6)
            c = mix(V3(0.006, 0.035, 0.14), V3(0.04, 0.28, 0.52), d)
            c = mix(c, V3(0.10, 0.50, 0.68), smooth(coast - 0.035, coast, land) * 0.75)
            b = 0.25
        } else {
            let e = clamp01((land - coast) / 0.42)
            let moist = n2.fbm(p * 2.6 + V3(4, 2, 1), 6)
            let tropical = 1 - smooth(0.0, 0.35, lat)
            var forest = mix(V3(0.30, 0.42, 0.17), V3(0.07, 0.25, 0.09), smooth(0.4, 0.62, moist) * (0.4 + 0.6 * tropical))
            let aridity = smooth(0.50, 0.40, moist) * smooth(0.08, 0.28, lat) * (1 - smooth(0.5, 0.7, lat))
            forest = mix(forest, V3(0.76, 0.64, 0.40), aridity)
            c = mix(forest, V3(0.52, 0.55, 0.47), smooth(0.62, 0.82, lat))
            c = mix(c, V3(0.42, 0.37, 0.31), smooth(0.45, 0.78, e))
            c = mix(c, V3(0.95, 0.96, 0.98), smooth(0.86, 1.0, e))
            b = 0.30 + e * 0.7
        }
        let iceEdge = lat + (n3.fbm(p * 5, 4) - 0.5) * 0.09
        c = mix(c, V3(0.94, 0.96, 1.0), smooth(0.86, 0.91, iceEdge))
        if iceEdge > 0.88 { b = max(b, 0.42) }
        let cloudBase = n3.fbm(p * 2.6 + n3.warp(p) * 0.9, 8)
        let cloud = smooth(0.54, 0.74, (cloudBase - 0.5) * 1.8 + 0.5) * 0.82
        c = mix(c, V3(1, 1, 1), cloud)
        return (c, b)
    }

    private static func jupiter(_ p: V3, _ n1: Noise3, _ n2: Noise3, _ n3: Noise3) -> V3 {
        let lat = asin(max(-1, min(1, p.y)))
        let turb = n1.fbm(V3(p.x * 3.5, p.y * 22, p.z * 3.5), 7)
        let shear = n2.fbm(V3(p.x * 9, p.y * 60, p.z * 9), 5)
        var band = 0.5 + 0.5 * sin(lat * 16 + (turb - 0.5) * 7)
        band = clamp01(band * 0.78 + (shear - 0.5) * 0.45 + 0.08)
        let stops: [V3] = [V3(0.42, 0.26, 0.17), V3(0.66, 0.44, 0.28), V3(0.84, 0.66, 0.48), V3(0.95, 0.88, 0.78), V3(0.97, 0.95, 0.90)]
        let s = band * 4
        let k = min(Int(s), 3)
        var c = mix(stops[k], stops[k + 1], s - Float(k))
        // Great red spot with a pale wake and a few small ovals.
        let lon = atan2(p.z, p.x)
        func oval(_ lon0: Float, _ lat0: Float, _ rx: Float, _ ry: Float) -> Float {
            var dl = lon - lon0
            if dl > .pi { dl -= 2 * .pi } else if dl < -.pi { dl += 2 * .pi }
            let dx = dl / rx, dy = (lat - lat0) / ry
            return 1 - smooth(0.6, 1.0, dx * dx + dy * dy)
        }
        let swirl = n3.fbm(V3(p.x * 14, p.y * 14, p.z * 14), 4)
        let spot = oval(1.0, -0.33, 0.26, 0.11)
        c = mix(c, V3(0.62, 0.27, 0.16), spot * (0.8 + 0.2 * swirl))
        c = mix(c, V3(0.93, 0.86, 0.76), oval(1.0, -0.33, 0.34, 0.15) * (1 - spot) * 0.25)
        c = mix(c, V3(0.96, 0.93, 0.88), oval(-1.8, 0.42, 0.06, 0.03) * 0.8)
        c = mix(c, V3(0.96, 0.93, 0.88), oval(2.6, -0.5, 0.05, 0.03) * 0.8)
        return c
    }

    private static func sun(_ p: V3, _ n1: Noise3, _ n2: Noise3, _ n3: Noise3) -> V3 {
        let gran = n1.fbm(p * 14 + n1.warp(p) * 0.5, 7)
        let cell = n2.fbm(p * 5, 5)
        var t = clamp01((gran - 0.5) * 2.4 + 0.52 + (cell - 0.5) * 0.5)
        t = t * t * 0.4 + t * 0.6
        var c: V3 = t < 0.5 ? mix(V3(0.68, 0.14, 0.01), V3(1.0, 0.45, 0.03), t * 2)
                            : mix(V3(1.0, 0.45, 0.03), V3(1.0, 0.90, 0.50), (t - 0.5) * 2)
        let spots = smooth(0.30, 0.22, n3.fbm(p * 3.4 + V3(2, 5, 1), 5))
        c = mix(c, V3(0.35, 0.07, 0.01), spots * 0.75)
        return c
    }

    // MARK: Craters

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Float {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Float(z >> 40) / Float(1 << 24)
        }
    }

    private static func addCraters(_ t: UnsafeMutablePointer<Float>, count: Int, maxRadius: Float, strength: Float, rng: inout SplitMix) {
        let w = width, h = height
        for _ in 0..<count {
            let lat0 = asin(2 * rng.next() - 1)
            let lon0 = rng.next() * 2 * .pi
            let r = min(0.006 / pow(max(rng.next(), 0.0005), 0.62), maxRadius)
            let amp = strength * (0.35 + min(r * 14, 1) * 0.65)
            let c = V3(cos(lat0) * cos(lon0), sin(lat0), cos(lat0) * sin(lon0))
            let reach = r * 1.35
            let rowTop = Int((0.5 - (lat0 + reach) / .pi) * Float(h)) - 1
            let rowBot = Int((0.5 - (lat0 - reach) / .pi) * Float(h)) + 1
            for y in max(0, rowTop)...min(h - 1, rowBot) {
                let lat = (0.5 - (Float(y) + 0.5) / Float(h)) * .pi
                let cl = max(cos(lat), 0.02)
                let dLon = min(.pi, reach / cl)
                let xc = Int(lon0 / (2 * .pi) * Float(w))
                let dx = Int(dLon / (2 * .pi) * Float(w)) + 1
                for off in -dx...dx {
                    let x = ((xc + off) % w + w) % w
                    let d = acos(max(-1, min(1, simd_dot(point(x, y), c)))) / r
                    guard d < 1.35 else { continue }
                    var dh: Float = 0
                    if d < 1 { dh = -amp * (1 - d * d) } else { dh = 0 }
                    dh += amp * 0.62 * exp(-pow((d - 1) / 0.14, 2))
                    if d > 1 { dh += amp * 0.10 * exp(-(d - 1) * 5) }
                    if d < 0.16, r > 0.05 { dh += amp * 0.5 * (1 - d / 0.16) }
                    t[y * w + x] += dh
                }
            }
        }
    }
}

// MARK: - SceneKit planet

/// Screen-space trackball. The planet keeps spinning about a tilted axis, can be flung
/// by dragging, and is pulled slightly toward the pointer while held. The moon is a
/// separate body that orbits, spins, and can be grabbed on its own.
final class PlanetController: NSObject, SCNSceneRendererDelegate {
    enum Grab { case planet, moon }

    let scene = SCNScene()
    private let shift = SCNNode(), planetNode = SCNNode()
    private let moonNode = SCNNode(), orbitTilt = SCNNode(), orbitRotor = SCNNode()
    private(set) var pointOfView: SCNNode!
    private let hasMoon: Bool

    var boost: Float = 1
    private let baseSpeed: Float
    private let axis: V3

    private var q = simd_quatf(angle: 0.4, axis: simd_normalize(V3(1, 0.3, 0.2)))
    private var omega: V3
    private var moonQ = simd_quatf(angle: 1.1, axis: simd_normalize(V3(0.2, 1, 0.1)))
    private var moonOmega = V3(0, 0.25, 0)
    private var orbitAngle: Float = 2.4

    private(set) var grab: Grab?
    private var offset = SIMD2<Float>(0, 0), target = SIMD2<Float>(0, 0)
    private var pop: Float = 1
    private var last: TimeInterval = 0

    init(kind: PlanetKind, maps: PlanetMaps, moon: PlanetMaps?) {
        baseSpeed = kind == .sun ? 0.10 : kind == .jupiter ? 0.30 : 0.20
        axis = simd_normalize(V3(-sin(0.38), cos(0.38), 0))
        omega = axis * baseSpeed
        hasMoon = moon != nil
        super.init()

        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 128
        sphere.firstMaterial = Self.material(maps, constant: kind == .sun)
        planetNode.geometry = sphere
        shift.addChildNode(planetNode)
        scene.rootNode.addChildNode(shift)

        switch kind {
        case .earth: shift.addChildNode(Self.glow(radius: 1.035, color: V3(0.30, 0.55, 1.0), power: 5.0, gain: 0.55))
        case .sun: shift.addChildNode(Self.glow(radius: 1.20, color: V3(1.0, 0.55, 0.12), power: 1.8, gain: 1.5))
        case .mars: shift.addChildNode(Self.glow(radius: 1.04, color: V3(0.9, 0.5, 0.35), power: 3.2, gain: 0.5))
        default: break
        }

        if let moon {
            let ms = SCNSphere(radius: 0.24)
            ms.segmentCount = 64
            ms.firstMaterial = Self.material(moon, constant: false)
            moonNode.geometry = ms
            // Fixed upper-right, like a distant companion: no orbit, so it never clips.
            moonNode.position = SCNVector3(2.15, 1.25, -0.6)
            orbitTilt.eulerAngles = SCNVector3(0, 0, 0)
            orbitRotor.addChildNode(moonNode)
            orbitTilt.addChildNode(orbitRotor)
            scene.rootNode.addChildNode(orbitTilt)
        }

        let amb = SCNNode(); amb.light = SCNLight(); amb.light?.type = .ambient
        amb.light?.intensity = kind == .sun ? 0 : 480
        amb.light?.color = NSColor(white: 0.5, alpha: 1)
        scene.rootNode.addChildNode(amb)
        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .omni
        key.light?.intensity = 1700
        key.position = SCNVector3(-4.5, 2.4, 4.2)
        scene.rootNode.addChildNode(key)

        let cam = SCNNode(); cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 28
        cam.position = SCNVector3(0, 0, moon != nil ? 5.9 : 4.9)
        scene.rootNode.addChildNode(cam)
        pointOfView = cam
    }

    private static func material(_ maps: PlanetMaps, constant: Bool) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = maps.color
        for prop in [m.diffuse] {
            prop.mipFilter = .linear
            prop.minificationFilter = .linear
            prop.magnificationFilter = .linear
            prop.maxAnisotropy = 8
        }
        if constant {
            m.lightingModel = .constant
            m.emission.contents = maps.color
        } else {
            m.lightingModel = .lambert
            if let b = maps.bump {
                m.normal.contents = b
                m.normal.intensity = 1.0
                m.normal.mipFilter = .linear
                m.normal.minificationFilter = .linear
                m.normal.magnificationFilter = .linear
            }
        }
        return m
    }

    private static func glow(radius: CGFloat, color: V3, power: Float, gain: Float) -> SCNNode {
        let s = SCNSphere(radius: radius)
        s.segmentCount = 96
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.black
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.fragment: """
        float rim = pow(1.0 - saturate(dot(normalize(_surface.normal), normalize(_surface.view))), \(power));
        _output.color = vec4(\(color.x), \(color.y), \(color.z), 1.0) * rim * \(gain);
        """]
        s.firstMaterial = m
        return SCNNode(geometry: s)
    }

    func hitMoon(_ hits: [SCNHitTestResult]) -> Bool {
        hasMoon && hits.contains { $0.node === moonNode }
    }

    func beginDrag(_ g: Grab) { grab = g }

    func endDrag() {
        grab = nil
        target = .zero
    }

    func drag(dx: Double, dy: Double, nx: Double, ny: Double) {
        guard let grab, dx != 0 || dy != 0 else { return }
        let k: Float = 0.009
        let spinAxis = V3(Float(dy), Float(dx), 0)
        let dq = simd_quatf(angle: simd_length(spinAxis) * k, axis: simd_normalize(spinAxis))
        let inst = spinAxis * k * 60
        switch grab {
        case .planet:
            q = simd_normalize(dq * q)
            omega = clampOmega(omega * 0.55 + inst * 0.45)
            target = SIMD2(Float(max(-1, min(1, nx))), Float(max(-1, min(1, ny)))) * 0.14
        case .moon:
            moonQ = simd_normalize(dq * moonQ)
            moonOmega = clampOmega(moonOmega * 0.55 + inst * 0.45)
        }
    }

    private func clampOmega(_ o: V3) -> V3 {
        let l = simd_length(o)
        return l > 16 ? o / l * 16 : o
    }

    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = last == 0 ? 0 : Float(min(time - last, 0.1))
        last = time

        if grab != .planet {
            // Ramp up quickly while busy, ease back gently when idle.
            omega += (axis * baseSpeed * boost - omega) * min(1, dt * (boost > 1 ? 4 : 1.1))
        }
        let a = simd_length(omega) * dt
        if a > 1e-6, grab != .planet {
            q = simd_normalize(simd_quatf(angle: a, axis: simd_normalize(omega)) * q)
        }
        planetNode.simdOrientation = q

        offset += (target - offset) * min(1, dt * 7)
        pop += ((grab == .planet ? 1.035 : 1) - pop) * min(1, dt * 8)
        shift.position = SCNVector3(CGFloat(offset.x), CGFloat(offset.y), 0)
        shift.scale = SCNVector3(CGFloat(pop), CGFloat(pop), CGFloat(pop))

        if hasMoon {
            if grab != .moon {
                
                moonOmega += (V3(0, 0.25, 0) - moonOmega) * min(1, dt * 1.1)
                let ma = simd_length(moonOmega) * dt
                if ma > 1e-6 { moonQ = simd_normalize(simd_quatf(angle: ma, axis: simd_normalize(moonOmega)) * moonQ) }
            }
            
            moonNode.simdOrientation = moonQ
        }
    }
}

final class PlanetSCNView: SCNView {
    weak var controller: PlanetController?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hits = hitTest(p, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        controller?.beginDrag(controller?.hitMoon(hits) == true ? .moon : .planet)
        NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let w = max(bounds.width, 1), h = max(bounds.height, 1)
        controller?.drag(dx: event.deltaX, dy: event.deltaY, nx: (p.x - w / 2) / (w / 2), ny: (p.y - h / 2) / (h / 2))
    }
    override func mouseUp(with event: NSEvent) {
        controller?.endDrag()
        NSCursor.openHand.set()
    }
}

private struct PlanetSceneView: NSViewRepresentable {
    let kind: PlanetKind
    let maps: PlanetMaps
    let moon: PlanetMaps?
    let spin: Double

    final class Coordinator { var controller: PlanetController? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlanetSCNView {
        let c = PlanetController(kind: kind, maps: maps, moon: moon)
        context.coordinator.controller = c
        let v = PlanetSCNView()
        v.controller = c
        v.scene = c.scene
        v.pointOfView = c.pointOfView
        v.delegate = c
        v.backgroundColor = .clear
        v.antialiasingMode = .multisampling4X
        v.preferredFramesPerSecond = 60
        v.rendersContinuously = true
        v.allowsCameraControl = false
        return v
    }

    func updateNSView(_ v: PlanetSCNView, context: Context) {
        context.coordinator.controller?.boost = Float(spin)
    }
}

/// A rotating, draggable planet. Textures are generated on first use.
struct PlanetView: View {
    let kind: PlanetKind
    var size: CGFloat = 320
    var spin: Double = 1
    var moon = false
    @State private var maps: PlanetMaps?
    @State private var moonMaps: PlanetMaps?

    var body: some View {
        ZStack {
            if let maps, !moon || moonMaps != nil {
                PlanetSceneView(kind: kind, maps: maps, moon: moon ? moonMaps : nil, spin: spin)
                    .transition(.opacity)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: moon ? size * 2.4 : size, height: moon ? size * 1.3 : size)
        .animation(.easeOut(duration: 0.6), value: maps != nil)
        .task {
            maps = await PlanetTextures.load(kind)
            if moon { moonMaps = await PlanetTextures.load(.mercury) }
        }
    }
}

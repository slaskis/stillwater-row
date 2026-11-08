import SceneKit
import UIKit
import simd

/// Light, fog, sky, rain, lanterns, birds and fireworks.
extension RiverScene {
    // Scene light units per web intensity unit (calibrated so dawn matches the original fixed lighting).
    static let sunScale = 975.0
    static let ambientScale = 545.0
    static let fillScale = 150.0

    // Storm targets, as in the web version's stormMix.
    static let stormFog: UInt32 = 0x3c4448, stormTop: UInt32 = 0x232a30, stormDeep: UInt32 = 0x10181a, stormRef: UInt32 = 0x4a5459

    // MARK: Setup

    func setUpSky() {
        let sphere = SCNSphere(radius: 8)   // inside the nearest fog start (12 m), so fog never touches it
        sphere.segmentCount = 32
        let m = skyMaterial
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.black
        m.ambient.contents = UIColor.black
        m.locksAmbientWithDiffuse = false
        m.cullMode = .front
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false
        m.shaderModifiers = [.surface: Self.skyShader]
        sphere.materials = [m]
        skyDome.geometry = sphere
        skyDome.renderingOrder = -10
        skyDome.castsShadow = false
        scene.rootNode.addChildNode(skyDome)
        scene.background.contents = UIColor.black
    }

    /// The web version's sky dome: horizon-to-top gradient, sun disc and glow, and stars at night.
    static let skyShader = """
    #pragma arguments
    float3 k_top;
    float3 k_hor;
    float3 k_sun;
    float3 k_sunDir;
    float k_stars;
    float k_disc;
    float k_glow;

    #pragma body
    float3 k_v = normalize((scn_frame.inverseViewTransform * float4(_surface.position, 0.0)).xyz);
    float k_h = max(k_v.y, 0.0);
    float3 k_c = mix(k_hor, k_top, pow(k_h, 0.5));
    float k_s = max(dot(k_v, normalize(k_sunDir)), 0.0);
    float k_d = smoothstep(1.0 - 1.7 / k_disc, 1.0 - 1.0 / k_disc, k_s);
    k_c += k_sun * (k_d * 1.4 + pow(k_s, k_disc * 0.2) * 0.45 + pow(k_s, 10.0) * k_glow);
    if (k_stars > 0.0) {
        float3 k_q = floor(k_v * 240.0);
        float k_r = fract(sin(dot(k_q, float3(12.9898, 78.233, 45.164))) * 43758.5453);
        float k_b = fract(sin(dot(k_q + 1.7, float3(12.9898, 78.233, 45.164))) * 43758.5453);
        float k_st = step(0.9972, k_r) * smoothstep(0.03, 0.3, k_v.y);
        k_c += float3(k_st * k_stars * (0.4 + 0.6 * k_b));
    }
    _surface.diffuse = float4(k_c, 1.0);
    """

    func makeRain() -> SCNParticleSystem {
        let ps = SCNParticleSystem()
        ps.particleImage = Tex.streak()
        ps.emitterShape = SCNBox(width: 70, height: 1, length: 70, chamferRadius: 0)
        ps.birthRate = 0
        ps.particleLifeSpan = 1.1
        ps.particleVelocity = 26
        ps.emittingDirection = SCNVector3(x: 0.08, y: -1, z: 0.05)
        ps.particleSize = 0.42
        ps.particleColor = UIColor(white: 0.85, alpha: 0.4)
        ps.blendMode = .alpha
        ps.isAffectedByGravity = false
        ps.isLightingEnabled = false
        ps.orientationMode = .billboardYAligned
        // Rain falls straight down in world space, wherever the camera looks; it follows the camera each frame.
        rainHolder.name = "rain"
        rainHolder.addParticleSystem(ps)
        scene.rootNode.addChildNode(rainHolder)
        return ps
    }

    func setUpNightLights() {
        boatLamp.position = SCNVector3(x: 0, y: 0.55, z: 3.9)
        let sprite = ScenePart.glow(1.3, at: SCNVector3(x: 0, y: 0, z: 0))
        boatLamp.addChildNode(sprite)
        boatLamp.isHidden = true
        boat.root.addChildNode(boatLamp)

        boatLampLight.type = .omni
        boatLampLight.color = UIColor(hex: 0xffcf8a)
        boatLampLight.intensity = 700
        boatLampLight.attenuationStartDistance = 0
        boatLampLight.attenuationEndDistance = 14
        boatLampLight.attenuationFalloffExponent = 2

        for node in lanternLights {
            let l = SCNLight()
            l.type = .omni
            l.color = UIColor(hex: 0xffc070)
            l.intensity = 0
            l.attenuationStartDistance = 0
            l.attenuationEndDistance = 22
            l.attenuationFalloffExponent = 2
            node.light = l
            node.isHidden = true
            scene.rootNode.addChildNode(node)
        }
    }

    // MARK: Look

    /// Sets the time of day / weather and the landscape. Rebuilds the scenery only if the landscape
    /// or the lanterns change. The storm, if any, keeps blending on top.
    func setLook(_ condition: Condition, scenery newScenery: Scenery) {
        let newLook = condition.look
        let rebuild = newScenery != scenery || newLook.lanterns != look.lanterns
        look = newLook
        scenery = newScenery

        let sunDir = simd_normalize(look.sunDirection)
        sunLight.color = UIColor(hex: look.sun)
        sunNode.simdPosition = sunDir * 100
        sunNode.simdLook(at: SIMD3<Float>(0, 0, 0))
        ambientLight.color = UIColor(hex: Palette.mixHex(look.hemiGround, look.hemiSky, 0.75))
        fillLight.color = UIColor(hex: look.hemiSky)

        let dirValue = NSValue(scnVector3: SCNVector3(x: sunDir.x, y: sunDir.y, z: sunDir.z))
        skyMaterial.setValue(Palette.linearVector(look.sun), forKey: "k_sun")
        skyMaterial.setValue(dirValue, forKey: "k_sunDir")
        skyMaterial.setValue(NSNumber(value: look.sunDisc), forKey: "k_disc")
        waterMaterial.setValue(Palette.linearVector(look.sun), forKey: "sunCol")
        waterMaterial.setValue(dirValue, forKey: "sunDir")

        let lanterns = look.lanterns
        boatLamp.isHidden = !lanterns
        boatLamp.light = lanterns ? boatLampLight : nil
        for n in lanternLights {
            n.isHidden = !lanterns
            if !lanterns { n.light?.intensity = 0 }
        }
        if lanterns || look.stars { birds.isHidden = true }

        applyAtmosphere(storm: stormK, flash: 0)
        if rebuild { clearChunks() }
    }

    /// Fog, sky, light and water from the current look blended toward the storm (k 0…1) and a lightning flash.
    func applyAtmosphere(storm k: Double, flash fl: Double) {
        let L = look
        appliedStorm = k
        appliedFlash = fl
        let fogHex = Palette.mixHex(Palette.mixHex(L.fog, Self.stormFog, k), 0xdfe6f0, fl * 0.45)
        scene.fogColor = UIColor(hex: fogHex)
        scene.fogStartDistance = CGFloat(lerp(L.fogNear, 14, k))
        scene.fogEndDistance = CGFloat(lerp(L.fogFar, 280, k))

        let top = Palette.mixHex(Palette.mixHex(L.skyTop, Self.stormTop, k), 0xcfd8e6, fl * 0.7)
        skyMaterial.setValue(Palette.linearVector(top), forKey: "k_top")
        skyMaterial.setValue(Palette.linearVector(fogHex), forKey: "k_hor")
        skyMaterial.setValue(NSNumber(value: L.glow * (1 - k)), forKey: "k_glow")
        skyMaterial.setValue(NSNumber(value: (L.stars ? 1.0 : 0.0) * (1 - k)), forKey: "k_stars")

        let hemi = L.hemiIntensity * (1 - 0.45 * k) + fl * 1.6
        ambientLight.intensity = CGFloat(hemi * Self.ambientScale)
        fillLight.intensity = CGFloat(hemi * Self.fillScale)
        sunLight.intensity = CGFloat(L.sunIntensity * (1 - 0.75 * k) * Self.sunScale)

        waterMaterial.setValue(Palette.linearVector(Palette.mixHex(L.deep, Self.stormDeep, k)), forKey: "deepCol")
        waterMaterial.setValue(Palette.linearVector(Palette.mixHex(L.reflection, Self.stormRef, k)), forKey: "skyCol")
        waterMaterial.setValue(NSNumber(value: L.specular * (1 - k)), forKey: "specK")
        let rk = L.rain ? 1.0 : (k > 0.4 ? (k - 0.4) / 0.6 : 0)
        waterMaterial.setValue(NSNumber(value: rk), forKey: "rainK")
        rain.birthRate = CGFloat(rk * 1600)
    }

    // MARK: Per frame

    /// Keeps the sky centred on the camera and moves the night lights to the lanterns nearest the boat.
    func updateAtmosphere(dt: Double, time: Double, distance: Double) {
        skyDome.simdPosition = cameraNode.simdPosition
        var ahead = cameraNode.simdWorldFront
        ahead.y = 0
        let len = simd_length(ahead)
        rainHolder.simdPosition = cameraNode.simdPosition + (len > 0.01 ? ahead / len * 12 : .zero) + SIMD3<Float>(0, 22, 0)
        if look.lanterns {
            // The next lantern on each side (every 60 m): fades in from 50 m ahead, out 10 m behind.
            for (i, node) in lanternLights.enumerated() {
                let side: Double = i == 0 ? 1 : -1
                let d = ((distance - 10) / 60).rounded(.up) * 60
                let a = d - distance
                let k = clamp((50 - a) / 15, 0, 1) * clamp((a + 10) / 5, 0, 1)
                let y = River.meshY(d, 1.6, side, scenery) + 3.1
                node.position = SCNVector3(x: Float(River.cx(d) + side * (River.width / 2 + 1.6)), y: Float(y), z: Float(-d))
                node.light?.intensity = CGFloat(900 * k * (d > 0 ? 1 : 0))
            }
        }
        updateBirds(dt: dt, time: time)
        updateFireworks(time: time)
    }

    // MARK: Birds

    func setUpBirds() {
        let g = SCNBox(width: 0.9, height: 0.04, length: 0.22, chamferRadius: 0)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor(hex: 0x2c3336)
        g.materials = [m]
        for i in 0..<7 {
            let b = SCNNode()
            let n = Float((i + 1) / 2)
            b.position = SCNVector3(x: (i % 2 == 1 ? 1 : -1) * n * 1.6, y: -n * 0.3, z: n * 1.4)
            let phase = Double.random(in: 0..<6)
            for s: Float in [1, -1] {
                let pivot = SCNNode()
                let w = SCNNode(geometry: g)
                w.position = SCNVector3(x: s * 0.45, y: 0, z: 0)
                pivot.addChildNode(w)
                b.addChildNode(pivot)
                birdWings.append((pivot, s, phase))
            }
            birds.addChildNode(b)
        }
        birds.isHidden = true
        scene.rootNode.addChildNode(birds)
    }

    /// A small V of birds crosses the sky now and then (not at night).
    func updateBirds(dt: Double, time: Double) {
        if look.lanterns || look.stars {
            birds.isHidden = true
            return
        }
        if birds.isHidden {
            guard time > birdNext else { return }
            let yaw = boat.root.eulerAngles.y
            let fx = -sin(yaw), fz = -cos(yaw)
            let side: Float = Bool.random() ? 1 : -1
            let p = boat.root.position
            birds.position = SCNVector3(x: p.x + fx * 90 - fz * side * 70, y: 26 + Float.random(in: 0..<14), z: p.z + fz * 90 + fx * side * 70)
            birdVelocity = SIMD3(fz * side * 9, 0, -fx * side * 9)
            birds.eulerAngles = SCNVector3(x: 0, y: atan2(birdVelocity.x, birdVelocity.z) + .pi, z: 0)
            birdLife = 0
            birds.isHidden = false
        }
        birdLife += dt
        birds.simdPosition += birdVelocity * Float(dt)
        for w in birdWings { w.node.eulerAngles.z = w.sign * Float(sin(time * 7 + w.phase) * 0.5) }
        if birdLife > 18 {
            birds.isHidden = true
            birdNext = time + 25 + Double.random(in: 0..<40)
        }
    }

    // MARK: Fireworks

    /// Fireworks over the river ahead of the boat: six bursts in different colours over about three seconds.
    func celebrate() {
        fireworksStart = lastTime
        fireworksFired = 0
    }

    private static let burstDelays: [Double] = [0, 0.45, 0.9, 1.35, 1.95, 2.6]

    private func updateFireworks(time: Double) {
        guard let start = fireworksStart else { return }
        while fireworksFired < Self.burstDelays.count, time >= start + Self.burstDelays[fireworksFired] {
            burst(fireworksFired)
            fireworksFired += 1
        }
        if fireworksFired >= Self.burstDelays.count { fireworksStart = nil }
    }

    private func burst(_ i: Int) {
        if fireworkHolders.isEmpty {
            for _ in 0..<Self.burstDelays.count {
                let n = SCNNode()
                scene.rootNode.addChildNode(n)
                fireworkHolders.append(n)
            }
        }
        let yaw = boat.root.eulerAngles.y
        let fx = -sin(yaw), fz = -cos(yaw), rx = cos(yaw), rz = -sin(yaw)
        let p = boat.root.position
        let ahead = 36 + Float(i) * 5, sx = Float.random(in: -15...15)
        let holder = fireworkHolders[i % fireworkHolders.count]
        holder.removeAllParticleSystems()
        holder.position = SCNVector3(x: p.x + fx * ahead + rx * sx, y: 9 + Float.random(in: 0..<6), z: p.z + fz * ahead + rz * sx)
        guard let ps = fireworkTemplate.copy() as? SCNParticleSystem else { return }
        ps.particleColor = UIColor(hue: CGFloat.random(in: 0..<1), saturation: 0.8, brightness: 1, alpha: 1)
        holder.addParticleSystem(ps)
    }

    static func makeFireworkTemplate() -> SCNParticleSystem {
        let ps = SCNParticleSystem()
        ps.particleImage = Tex.fireworkSpark()
        ps.birthRate = 500
        ps.emissionDuration = 0.08
        ps.loops = false
        ps.birthDirection = .random
        ps.particleLifeSpan = 1.9
        ps.particleLifeSpanVariation = 0.6
        ps.particleVelocity = 8
        ps.particleVelocityVariation = 4
        ps.acceleration = SCNVector3(x: 0, y: -4, z: 0)
        ps.dampingFactor = 0.5
        ps.particleSize = 0.55
        ps.blendMode = .additive
        ps.isLightingEnabled = false
        ps.isAffectedByGravity = false
        ps.orientationMode = .billboardScreenAligned
        let fade = CAKeyframeAnimation()
        fade.values = [1.0, 1.0, 0.0]
        fade.keyTimes = [0, 0.55, 1]
        fade.duration = 1
        ps.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
        return ps
    }
}

import Foundation
import MapLibre
import MetalKit
import simd
import TransitCore

/// Bus geometry participates in MLNMapView's Metal render pass and native 3D depth buffer.
final class NativeBusLayer: MLNCustomStyleLayer {
    var onError: ((String) -> Void)?
    var onSelectedPoint: ((CGPoint?) -> Void)?
    var selectedID: String? {
        didSet { if selectedID != oldValue { selectionStartedAt = CACurrentMediaTime(); setNeedsDisplay() } }
    }
    var highlightSelected = true {
        didSet { if highlightSelected != oldValue { selectionStartedAt = CACurrentMediaTime(); setNeedsDisplay() } }
    }
    var reduceMotion = false {
        didSet {
            if reduceMotion != oldValue {
                if reduceMotion { motion.finishAnimations(time: CACurrentMediaTime(), now: Date()) }
                setNeedsDisplay()
            }
        }
    }
    private var selectionStartedAt: CFTimeInterval = 0
    private var motion = VehicleMotion()
    private var pipeline: MTLRenderPipelineState?
    private var outlinePipeline: MTLRenderPipelineState?
    private var shadowPipeline: MTLRenderPipelineState?
    private var symbolPipeline: MTLRenderPipelineState?
    private var normalDepth: MTLDepthStencilState?
    private var highlightDepth: MTLDepthStencilState?
    private var shadowDepth: MTLDepthStencilState?
    private var vertexBuffer: MTLBuffer?
    private var outlineBuffer: MTLBuffer?
    private var shadowBuffer: MTLBuffer?
    private var instanceBuffers: [MTLBuffer] = []
    private var bufferBusy = [false, false, false]
    private let bufferLock = NSLock()
    private var vertexCount = 0
    private var outlineCount = 0
    private var drawableSize = CGSize.zero
    private var hitPoints: [(id: String, point: CGPoint, size: CGFloat)] = []
    private static let maximumDetailed = 240
    private(set) var inputVehicleCount = 0
    private(set) var renderedVehicleCount = 0
    private(set) var symbolVehicleCount = 0
    private(set) var modelVehicleCount = 0
    private(set) var lastEncodeMilliseconds = 0.0
    private static let origin = Coordinate(latitude: 25.04, longitude: 121.55)
    private static let circumference = 40_075_016.68557849

    // SIMD4 alignment matches Metal: vertices 48, instances 32, uniforms 96 bytes.
    private struct Vertex { var position: SIMD4<Float>; var normal: SIMD4<Float>; var color: SIMD4<Float> }
    private struct Instance { var position: SIMD4<Float>; var style: SIMD4<Float> }
    private struct Uniforms { var matrix: simd_float4x4; var mode: SIMD4<Float>; var viewDirection: SIMD4<Float> }

    func ingest(_ vehicles: [BusVehicle], time: TimeInterval) {
        inputVehicleCount = vehicles.count
        motion.ingest(vehicles, time: time, now: Date())
        setNeedsDisplay()
    }
    func pose(id: String, time: TimeInterval, now: Date) -> VehiclePose? { motion.pose(id: id, time: time, now: now) }
    func isAnimating(time: TimeInterval, now: Date) -> Bool {
        motion.isAnimating(time: time, now: now) || (selectedID != nil && !reduceMotion && time - selectionStartedAt < 0.45)
    }

    override func didMove(to mapView: MLNMapView) {
        let resource = mapView.backendResource()
        guard let device = resource.device else { onError?("此裝置無法建立 Metal 地圖圖層"); return }
        do {
            let library = try device.makeDefaultLibrary(bundle: .main)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "busVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "busFragment")
            descriptor.colorAttachments[0].pixelFormat = resource.mtkView.colorPixelFormat
            let color = descriptor.colorAttachments[0]!
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .sourceAlpha
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .one
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            descriptor.depthAttachmentPixelFormat = resource.mtkView.depthStencilPixelFormat
            descriptor.stencilAttachmentPixelFormat = resource.mtkView.depthStencilPixelFormat
            descriptor.rasterSampleCount = resource.mtkView.sampleCount
            descriptor.label = "Instanced gray buses"
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            descriptor.inputPrimitiveTopology = .line
            descriptor.label = "Selected bus outline"
            outlinePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            descriptor.inputPrimitiveTopology = .triangle
            descriptor.vertexFunction = library.makeFunction(name: "busShadowVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "busShadowFragment")
            descriptor.label = "Soft road contact shadows"
            shadowPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            descriptor.vertexFunction = library.makeFunction(name: "busSymbolVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "busSymbolFragment")
            descriptor.label = "All received city buses"
            symbolPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            let depth = MTLDepthStencilDescriptor()
            depth.depthCompareFunction = .lessEqual
            depth.isDepthWriteEnabled = true
            normalDepth = device.makeDepthStencilState(descriptor: depth)
            depth.isDepthWriteEnabled = false
            shadowDepth = device.makeDepthStencilState(descriptor: depth)
            depth.depthCompareFunction = .always
            depth.isDepthWriteEnabled = false
            highlightDepth = device.makeDepthStencilState(descriptor: depth)

            let vertices = mesh()
            vertexCount = vertices.count
            vertexBuffer = vertices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            let edges = outline()
            outlineCount = edges.count
            outlineBuffer = edges.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            let shadowPositions: [SIMD2<Float>] = [SIMD2(-1.75,-6.4),SIMD2(1.75,-6.4),SIMD2(1.75,6.4),
                                                    SIMD2(-1.75,-6.4),SIMD2(1.75,6.4),SIMD2(-1.75,6.4)]
            let shadow = shadowPositions.map { p in
                Vertex(position: SIMD4(p.x,p.y,0.035,0), normal: SIMD4(p.x / 1.75,p.y / 6.4,0,0), color: .zero)
            }
            shadowBuffer = shadow.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            instanceBuffers = (0..<3).compactMap { _ in device.makeBuffer(length: MemoryLayout<Instance>.stride * 512, options: .storageModeShared) }
            guard instanceBuffers.count == 3, vertexBuffer != nil, outlineBuffer != nil, shadowBuffer != nil else { throw FeedError.invalid("Metal 記憶體") }
            drawableSize = resource.mtkView.drawableSize
        } catch {
            onError?("公車 3D 圖層載入失敗；仍可使用路線與站牌查詢")
        }
    }

    override func willMove(from mapView: MLNMapView) {
        pipeline = nil; outlinePipeline = nil; shadowPipeline = nil; symbolPipeline = nil
        vertexBuffer = nil; outlineBuffer = nil; shadowBuffer = nil
        instanceBuffers = []; hitPoints = []
    }

    override func draw(in mapView: MLNMapView, with context: MLNStyleLayerDrawingContext) {
        let encodingStarted = CACurrentMediaTime()
        guard let encoder = renderEncoder, let commandBuffer, let pipeline, let outlinePipeline, let shadowPipeline, let symbolPipeline,
              let vertexBuffer, let outlineBuffer, let shadowBuffer, instanceBuffers.count == 3,
              let normalDepth, let highlightDepth, let shadowDepth else { return }
        bufferLock.lock()
        let slot = bufferBusy.firstIndex(of: false)
        if let slot { bufferBusy[slot] = true }
        bufferLock.unlock()
        guard let slot else { setNeedsDisplay(); return }
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.bufferLock.lock(); self.bufferBusy[slot] = false; self.bufferLock.unlock()
        }
        let worldSize = 512 * pow(2, context.zoomLevel)
        let origin = Self.origin.mercator
        let metersPerWorld = Self.circumference * cos(Self.origin.latitude * .pi / 180)
        let pixelsPerMeter = worldSize / metersPerWorld
        var localToWorld = matrix_identity_double4x4
        localToWorld.columns.0.x = pixelsPerMeter
        localToWorld.columns.1.y = -pixelsPerMeter
        // MapLibre's native projection already converts Z meters to world pixels.
        localToWorld.columns.3 = SIMD4(origin.x * worldSize, origin.y * worldSize, 0, 1)
        // Match native buildings' near clipping. Multiplication in double avoids Mercator jitter.
        let projection = matrix(context.nearClippedProjectionMatrix) * localToWorld
        func floatColumn(_ value: SIMD4<Double>) -> SIMD4<Float> {
            SIMD4(Float(value.x), Float(value.y), Float(value.z), Float(value.w))
        }
        let gpuProjection = simd_float4x4(columns: (floatColumn(projection.columns.0), floatColumn(projection.columns.1),
                                                  floatColumn(projection.columns.2), floatColumn(projection.columns.3)))
        let heading = Float(mapView.camera.heading * .pi / 180), pitch = Float(mapView.camera.pitch * .pi / 180)
        let detailOpacity = Float(min(1, max(0, (context.zoomLevel - 15.0) / 1.0)))
        var uniforms = Uniforms(matrix: gpuProjection, mode: SIMD4(0, 0, detailOpacity, 0),
                                viewDirection: SIMD4(-sin(heading) * sin(pitch), -cos(heading) * sin(pitch), cos(pitch), 0))
        let time = CACurrentMediaTime()
        let selection = reduceMotion ? 1 : min(1, max(0, (time - selectionStartedAt) / 0.45))
        let selectionStrength = Float(selection * selection * (3 - 2 * selection))
        let poses = motion.poses(time: time, now: Date())
        var candidates: [(pose: VehiclePose, instance: Instance, point: CGPoint, size: CGFloat, score: Double)] = []
        for pose in poses {
            let mercator = pose.coordinate.mercator
            let east = (mercator.x - origin.x) * metersPerWorld
            let north = -(mercator.y - origin.y) * metersPerWorld
            let clip = projection * SIMD4(east, north, 1.75, 1)
            guard clip.w > 0 else { continue }
            let ndc = clip / clip.w
            guard abs(ndc.x) < 1.2, abs(ndc.y) < 1.2 else { continue }
            let screen = CGPoint(x: (ndc.x + 1) * context.size.width / 2,
                                 y: (1 - ndc.y) * context.size.height / 2)
            let selected = pose.id == selectedID
            let instance = Instance(position: SIMD4(Float(east), Float(north), 0, 1),
                                    style: SIMD4(Float(pose.heading * .pi / 180), selected ? selectionStrength : 0,
                                                 pose.stale ? 1 : 0, Float(pose.traveledDistance.truncatingRemainder(dividingBy: .pi * 0.98) / 0.49)))
            let angle = pose.heading * .pi / 180
            let front = projection * SIMD4(east + sin(angle) * 6, north + cos(angle) * 6, 1.75, 1)
            let screenLength = hypot((front.x / front.w - ndc.x) * context.size.width / 2,
                                     (front.y / front.w - ndc.y) * context.size.height / 2)
            candidates.append((pose, instance, screen, max(22, min(38, screenLength + 8)), selected ? -1 : ndc.x * ndc.x + ndc.y * ndc.y))
        }
        // Every received bus in the viewport remains visible. Only the expensive
        // wheel/window mesh is limited; overflow keeps its small direction symbol.
        let detailed: [(pose: VehiclePose, instance: Instance, point: CGPoint, size: CGFloat, score: Double)]
        if detailOpacity > 0.001 {
            detailed = Array(candidates.sorted { $0.score < $1.score }.prefix(Self.maximumDetailed))
        } else { detailed = candidates.filter { $0.pose.id == selectedID } }
        let detailedIDs = Set(detailed.map { $0.pose.id })
        let symbols = candidates.compactMap { item -> Instance? in
            let opacity: Float = item.pose.id == selectedID ? 0 : detailedIDs.contains(item.pose.id) ? 1 - detailOpacity : 1
            guard opacity > 0.001 else { return nil }
            var instance = item.instance; instance.style.w = opacity
            return instance
        }
        hitPoints = candidates.map { ($0.pose.id, $0.point, $0.size) }
        var instances = symbols + detailed.map(\.instance)
        let selected = candidates.first { $0.pose.id == selectedID }
        onSelectedPoint?(selected?.point)
        let selectedOffset = instances.count * MemoryLayout<Instance>.stride
        if let selected { instances.append(selected.instance) }
        let bytesNeeded = max(1, instances.count) * MemoryLayout<Instance>.stride
        if instanceBuffers[slot].length < bytesNeeded {
            guard let device = mapView.backendResource().device,
                  let larger = device.makeBuffer(length: max(bytesNeeded, instanceBuffers[slot].length * 2), options: .storageModeShared) else {
                onError?("公車圖層記憶體不足"); return
            }
            instanceBuffers[slot] = larger
        }
        let buffer = instanceBuffers[slot]
        instances.withUnsafeBytes { bytes in
            if let address = bytes.baseAddress, bytes.count > 0 { buffer.contents().copyMemory(from: address, byteCount: bytes.count) }
        }
        drawableSize = mapView.backendResource().mtkView.drawableSize
        // Custom layers inherit a 2D sublayer depth range. Restore the native 3D viewport.
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: drawableSize.width, height: drawableSize.height, znear: 0, zfar: 1))
        encoder.setCullMode(.none)
        if !symbols.isEmpty {
            var symbolUniforms = uniforms
            symbolUniforms.viewDirection = SIMD4(Float(context.size.width), Float(context.size.height), selectedID == nil ? 1 : 0.52, 0)
            encoder.setRenderPipelineState(symbolPipeline)
            encoder.setDepthStencilState(highlightDepth)
            encoder.setVertexBytes(&symbolUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setVertexBuffer(buffer, offset: 0, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: symbols.count)
        }
        let modelOffset = symbols.count * MemoryLayout<Instance>.stride
        encoder.setRenderPipelineState(shadowPipeline)
        encoder.setDepthStencilState(shadowDepth)
        encoder.setVertexBuffer(shadowBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setVertexBuffer(buffer, offset: modelOffset, index: 2)
        if !detailed.isEmpty { encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: detailed.count) }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(normalDepth)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setVertexBuffer(buffer, offset: modelOffset, index: 2)
        let normalCount = detailed.count
        if normalCount > 0 { encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount, instanceCount: normalCount) }
        if selected != nil {
            encoder.setVertexBuffer(buffer, offset: selectedOffset, index: 2)
            if highlightSelected {
                encoder.setDepthStencilState(highlightDepth)
                uniforms.mode.x = 1
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount, instanceCount: 1)
            }
            uniforms.mode.x = 2
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setRenderPipelineState(outlinePipeline)
            encoder.setVertexBuffer(outlineBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: outlineCount, instanceCount: 1)
        }
        renderedVehicleCount = candidates.count
        symbolVehicleCount = symbols.count
        modelVehicleCount = detailed.count
        lastEncodeMilliseconds = (CACurrentMediaTime() - encodingStarted) * 1000
    }

    func hitTest(_ point: CGPoint) -> String? {
        hitPoints.filter { hypot($0.point.x - point.x, $0.point.y - point.y) <= $0.size }
            .min { hypot($0.point.x - point.x, $0.point.y - point.y) < hypot($1.point.x - point.x, $1.point.y - point.y) }?.id
    }
#if DEBUG
    func testVisiblePoint(in bounds: CGRect) -> (id: String, point: CGPoint)? {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        return hitPoints.filter { bounds.contains($0.point) }
            .min { hypot($0.point.x - center.x, $0.point.y - center.y) < hypot($1.point.x - center.x, $1.point.y - center.y) }
            .map { ($0.id, $0.point) }
    }
#endif

    private func matrix(_ m: MLNMatrix4) -> simd_double4x4 {
        // MLNMatrix4 stores four consecutive columns, matching the SDK's official Metal example.
        simd_double4x4(columns: (SIMD4(m.m00, m.m01, m.m02, m.m03), SIMD4(m.m10, m.m11, m.m12, m.m13),
                                SIMD4(m.m20, m.m21, m.m22, m.m23), SIMD4(m.m30, m.m31, m.m32, m.m33)))
    }

    private func mesh() -> [Vertex] {
        var vertices: [Vertex] = []
        func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, color: SIMD3<Float>,
                      normal: SIMD3<Float>? = nil, material: Float = 0, wheelY: Float = 0) {
            let n = normal ?? simd_normalize(simd_cross(b - a, c - a))
            for p in [a,b,c] {
                vertices.append(Vertex(position: SIMD4(p.x,p.y,p.z,wheelY), normal: SIMD4(n.x,n.y,n.z,material),
                                       color: SIMD4(color.x,color.y,color.z,1)))
            }
        }
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                  color: SIMD3<Float>, normal: SIMD3<Float>? = nil, material: Float = 0, wheelY: Float = 0) {
            triangle(a,b,c,color:color,normal:normal,material:material,wheelY:wheelY)
            triangle(a,c,d,color:color,normal:normal,material:material,wheelY:wheelY)
        }
        func shell(_ rings: [[SIMD3<Float>]], shade: Float) {
            for level in 1..<rings.count {
                for i in 0..<8 {
                    let j = (i + 1) % 8
                    quad(rings[level-1][i],rings[level-1][j],rings[level][j],rings[level][i], color: SIMD3(repeating: shade))
                }
            }
            let roof = rings.last!, center = roof.reduce(SIMD3<Float>.zero, +) / 8
            for i in 0..<8 { triangle(center,roof[i],roof[(i+1)%8],color:SIMD3(repeating: shade + 0.06),normal:SIMD3(0,0,1)) }
        }
        // Chamfered corners and a bevel into the roof retain the simple gray silhouette.
        shell([bodyRing(width:2.42,length:11.66,z:0.42),bodyRing(width:2.55,length:11.8,z:0.64),
               bodyRing(width:2.55,length:11.8,z:3.15),bodyRing(width:2.30,length:11.54,z:3.40)],shade:0.73)
        shell([bodyRing(width:1.65,length:3.8,z:3.40,y:-0.45),bodyRing(width:1.53,length:3.68,z:3.55,y:-0.45)],shade:0.77)
        let glass = SIMD3<Float>(0.33,0.36,0.38)
        quad(SIMD3(-1.04,5.91,1.99),SIMD3(1.04,5.91,1.99),SIMD3(1.04,5.91,3.05),SIMD3(-1.04,5.91,3.05),
             color:glass,normal:SIMD3(0,1,0),material:1)
        quad(SIMD3(-0.98,-5.91,2.11),SIMD3(0.98,-5.91,2.11),SIMD3(0.98,-5.91,3.0),SIMD3(-0.98,-5.91,3.0),
             color:glass,normal:SIMD3(0,-1,0),material:1)
        for side: Float in [-1,1] {
            let x = side * 1.281
            for (start, end): (Float, Float) in [(-5.2,-2.9),(-2.75,-0.45),(-0.30,2.0),(2.15,5.18)] {
                quad(SIMD3(x,start,1.92),SIMD3(x,end,1.92),SIMD3(x,end,3.0),SIMD3(x,start,3.0),
                     color:glass,normal:SIMD3(side,0,0),material:1)
            }
            for wheelY: Float in [-3.55,3.65] {
                let inner = side * 1.18, outer = side * 1.38, radius: Float = 0.49
                let hub = SIMD3<Float>(outer,wheelY,0.51)
                for i in 0..<20 {
                    let a = Float(i) * .pi / 10, b = Float(i+1) * .pi / 10
                    let p = SIMD3<Float>(outer,wheelY + cos(a)*radius,0.51 + sin(a)*radius)
                    let q = SIMD3<Float>(outer,wheelY + cos(b)*radius,0.51 + sin(b)*radius)
                    triangle(hub,p,q,color:SIMD3(repeating:0.22),normal:SIMD3(side,0,0),material:2,wheelY:wheelY)
                    quad(SIMD3(inner,p.y,p.z),p,q,SIMD3(inner,q.y,q.z),color:SIMD3(repeating:0.20),
                         normal:SIMD3(0,cos((a+b)/2),sin((a+b)/2)),material:2,wheelY:wheelY)
                    let hubP = SIMD3<Float>(outer + side*0.008,wheelY + cos(a)*0.235,0.51 + sin(a)*0.235)
                    let hubQ = SIMD3<Float>(outer + side*0.008,wheelY + cos(b)*0.235,0.51 + sin(b)*0.235)
                    triangle(SIMD3(outer + side*0.008,wheelY,0.51),hubP,hubQ,color:SIMD3(repeating:0.48),
                             normal:SIMD3(side,0,0),wheelY:wheelY)
                }
                // Four small spokes make rolling visible when zoomed in, without extra textures.
                for i in 0..<4 {
                    let a = Float(i) * .pi / 2
                    let along = SIMD2<Float>(cos(a),sin(a)), cross = SIMD2<Float>(-sin(a),cos(a)) * 0.025
                    let center = SIMD2<Float>(wheelY,0.51)
                    let short = along * Float(0.06), long = along * Float(0.23)
                    let innerSpoke = center + short, outerSpoke = center + long
                    let points: [SIMD2<Float>] = [innerSpoke - cross,outerSpoke - cross,outerSpoke + cross,innerSpoke + cross]
                    let x = outer + side*0.012
                    quad(SIMD3(x,points[0].x,points[0].y),SIMD3(x,points[1].x,points[1].y),
                         SIMD3(x,points[2].x,points[2].y),SIMD3(x,points[3].x,points[3].y),color:SIMD3(repeating:0.31),
                         normal:SIMD3(side,0,0),wheelY:wheelY)
                }
            }
            let lightX = side * 0.88
            quad(SIMD3(lightX-0.20,5.915,1.12),SIMD3(lightX+0.20,5.915,1.12),
                 SIMD3(lightX+0.20,5.915,1.25),SIMD3(lightX-0.20,5.915,1.25),
                 color:SIMD3(0.92,0.92,0.88),normal:SIMD3(0,1,0),material:3)
            quad(SIMD3(lightX-0.07,-5.915,1.14),SIMD3(lightX+0.07,-5.915,1.14),
                 SIMD3(lightX+0.07,-5.915,1.45),SIMD3(lightX-0.07,-5.915,1.45),
                 color:SIMD3(0.56,0.24,0.22),normal:SIMD3(0,-1,0),material:3)
        }
        return vertices
    }

    private func bodyRing(width: Float, length: Float, z: Float, y: Float = 0) -> [SIMD3<Float>] {
        let x = width/2, l = length/2, bevel: Float = min(0.22,width/5)
        return [SIMD3(-x+bevel,y-l,z),SIMD3(x-bevel,y-l,z),SIMD3(x,y-l+bevel,z),SIMD3(x,y+l-bevel,z),
                SIMD3(x-bevel,y+l,z),SIMD3(-x+bevel,y+l,z),SIMD3(-x,y+l-bevel,z),SIMD3(-x,y-l+bevel,z)]
    }

    private func outline() -> [Vertex] {
        let lower = bodyRing(width:2.56,length:11.81,z:0.43), upper = bodyRing(width:2.32,length:11.56,z:3.42)
        var edges: [(SIMD3<Float>,SIMD3<Float>)] = []
        for i in 0..<8 {
            edges.append((lower[i],lower[(i+1)%8])); edges.append((upper[i],upper[(i+1)%8]))
            if i % 2 == 0 { edges.append((lower[i],upper[i])) }
        }
        return edges.flatMap { a,b in [a,b].map { p in Vertex(position:SIMD4(p.x,p.y,p.z,0),normal:SIMD4(0,0,1,0),color:SIMD4(0.12,0.42,0.96,1)) } }
    }
}

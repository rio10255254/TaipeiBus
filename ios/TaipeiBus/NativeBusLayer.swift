import Foundation
import MapLibre
import MetalKit
import simd
import TransitCore

/// Bus geometry participates in MLNMapView's Metal render pass and native 3D depth buffer.
final class NativeBusLayer: MLNCustomStyleLayer {
    var onError: ((String) -> Void)?
    var onSelectedPoint: ((CGPoint?) -> Void)?
    var selectedID: String?
    var highlightSelected = true
    private var motion = VehicleMotion()
    private var pipeline: MTLRenderPipelineState?
    private var outlinePipeline: MTLRenderPipelineState?
    private var normalDepth: MTLDepthStencilState?
    private var highlightDepth: MTLDepthStencilState?
    private var vertexBuffer: MTLBuffer?
    private var outlineBuffer: MTLBuffer?
    private var instanceBuffers: [MTLBuffer] = []
    private var bufferBusy = [false, false, false]
    private let bufferLock = NSLock()
    private var vertexCount = 0
    private var outlineCount = 0
    private var drawableSize = CGSize.zero
    private var hitPoints: [(id: String, point: CGPoint, size: CGFloat)] = []
    private static let maximumVisible = 240
    private static let origin = Coordinate(latitude: 25.04, longitude: 121.55)
    private static let circumference = 40_075_016.68557849

    // SIMD4 alignment matches Metal's layout. Instances are 32 bytes; uniforms are 80 bytes.
    private struct Vertex { var position: SIMD4<Float>; var color: SIMD4<Float> }
    private struct Instance { var position: SIMD4<Float>; var style: SIMD4<Float> }
    private struct Uniforms { var matrix: simd_float4x4; var mode: SIMD4<Float> }

    func ingest(_ vehicles: [BusVehicle], time: TimeInterval) {
        motion.ingest(vehicles, time: time, now: Date())
        setNeedsDisplay()
    }
    func pose(id: String, time: TimeInterval, now: Date) -> VehiclePose? { motion.pose(id: id, time: time, now: now) }
    func isAnimating(time: TimeInterval, now: Date) -> Bool { motion.isAnimating(time: time, now: now) }

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
            let depth = MTLDepthStencilDescriptor()
            depth.depthCompareFunction = .lessEqual
            depth.isDepthWriteEnabled = true
            normalDepth = device.makeDepthStencilState(descriptor: depth)
            depth.depthCompareFunction = .always
            depth.isDepthWriteEnabled = false
            highlightDepth = device.makeDepthStencilState(descriptor: depth)

            let vertices = mesh()
            vertexCount = vertices.count
            vertexBuffer = vertices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            let edges = outline()
            outlineCount = edges.count
            outlineBuffer = edges.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            instanceBuffers = (0..<3).compactMap { _ in device.makeBuffer(length: MemoryLayout<Instance>.stride * (Self.maximumVisible + 1), options: .storageModeShared) }
            guard instanceBuffers.count == 3, vertexBuffer != nil, outlineBuffer != nil else { throw FeedError.invalid("Metal 記憶體") }
            drawableSize = resource.mtkView.drawableSize
        } catch {
            onError?("公車 3D 圖層載入失敗；仍可使用路線與站牌查詢")
        }
    }

    override func willMove(from mapView: MLNMapView) {
        pipeline = nil; outlinePipeline = nil; vertexBuffer = nil; outlineBuffer = nil
        instanceBuffers = []; hitPoints = []
    }

    override func draw(in mapView: MLNMapView, with context: MLNStyleLayerDrawingContext) {
        guard let encoder = renderEncoder, let commandBuffer, let pipeline, let outlinePipeline,
              let vertexBuffer, let outlineBuffer, instanceBuffers.count == 3,
              let normalDepth, let highlightDepth else { return }
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
        var uniforms = Uniforms(matrix: simd_float4x4(projection), mode: .zero)
        let poses = motion.poses(time: CACurrentMediaTime(), now: Date())
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
                                    style: SIMD4(Float(pose.heading * .pi / 180), selected ? 1 : 0, pose.stale ? 1 : 0, 0))
            let front = projection * SIMD4(east, north + 6, 1.75, 1)
            let screenLength = abs((front.y / front.w - ndc.y) * context.size.height / 2)
            candidates.append((pose, instance, screen, max(14, min(30, screenLength + 8)), selected ? -1 : ndc.x * ndc.x + ndc.y * ndc.y))
        }
        candidates.sort { $0.score < $1.score }
        candidates = Array(candidates.prefix(Self.maximumVisible))
        hitPoints = candidates.map { ($0.pose.id, $0.point, $0.size) }
        var instances = candidates.filter { !highlightSelected || $0.pose.id != selectedID }.map(\.instance)
        let selected = candidates.first { $0.pose.id == selectedID }
        onSelectedPoint?(selected?.point)
        let selectedOffset = instances.count * MemoryLayout<Instance>.stride
        if let selected { instances.append(selected.instance) }
        let buffer = instanceBuffers[slot]
        instances.withUnsafeBytes { bytes in
            if let address = bytes.baseAddress, bytes.count > 0 { buffer.contents().copyMemory(from: address, byteCount: bytes.count) }
        }
        drawableSize = mapView.backendResource().mtkView.drawableSize
        // Custom layers inherit a 2D sublayer depth range. Restore the native 3D viewport.
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: drawableSize.width, height: drawableSize.height, znear: 0, zfar: 1))
        encoder.setCullMode(.none)
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(normalDepth)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setVertexBuffer(buffer, offset: 0, index: 2)
        let normalCount = candidates.filter { !highlightSelected || $0.pose.id != selectedID }.count
        if normalCount > 0 { encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount, instanceCount: normalCount) }
        if selected != nil {
            encoder.setVertexBuffer(buffer, offset: selectedOffset, index: 2)
            if highlightSelected {
                encoder.setDepthStencilState(highlightDepth)
                uniforms.mode.x = 1
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount, instanceCount: 1)
            }
            uniforms.mode.x = 2
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setRenderPipelineState(outlinePipeline)
            encoder.setVertexBuffer(outlineBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: outlineCount, instanceCount: 1)
        }
    }

    func hitTest(_ point: CGPoint) -> String? {
        hitPoints.filter { hypot($0.point.x - point.x, $0.point.y - point.y) <= $0.size }
            .min { hypot($0.point.x - point.x, $0.point.y - point.y) < hypot($1.point.x - point.x, $1.point.y - point.y) }?.id
    }

    private func matrix(_ m: MLNMatrix4) -> simd_double4x4 {
        // MLNMatrix4 stores four consecutive columns, matching the SDK's official Metal example.
        simd_double4x4(columns: (SIMD4(m.m00, m.m01, m.m02, m.m03), SIMD4(m.m10, m.m11, m.m12, m.m13),
                                SIMD4(m.m20, m.m21, m.m22, m.m23), SIMD4(m.m30, m.m31, m.m32, m.m33)))
    }

    private func mesh() -> [Vertex] {
        var vertices: [Vertex] = []
        func box(width: Float, length: Float, bottom: Float, top: Float, y: Float = 0, shade: Float) {
            let x = width / 2, l = length / 2
            let points: [SIMD4<Float>] = [SIMD4(-x, y-l, bottom, 1), SIMD4(x, y-l, bottom, 1), SIMD4(x, y+l, bottom, 1), SIMD4(-x, y+l, bottom, 1),
                                         SIMD4(-x, y-l, top, 1), SIMD4(x, y-l, top, 1), SIMD4(x, y+l, top, 1), SIMD4(-x, y+l, top, 1)]
            let faces: [([Int], Float)] = [([0,1,2,3], 0.7), ([4,7,6,5], 1.12), ([0,4,5,1], 0.85),
                                         ([1,5,6,2], 0.9), ([2,6,7,3], 0.76), ([3,7,4,0], 1.0)]
            for (indices, light) in faces {
                let color = SIMD4<Float>(repeating: min(0.92, shade * light))
                for index in [indices[0], indices[1], indices[2], indices[0], indices[2], indices[3]] {
                    vertices.append(Vertex(position: points[index], color: SIMD4(color.x, color.y, color.z, 1)))
                }
            }
        }
        box(width: 2.55, length: 11.8, bottom: 0.28, top: 3.45, shade: 0.66)
        box(width: 1.8, length: 5.2, bottom: 3.45, top: 3.56, shade: 0.76)
        box(width: 2.25, length: 0.04, bottom: 2, top: 3.16, y: 5.92, shade: 0.32)
        box(width: 2.7, length: 0.95, bottom: 0.12, top: 0.85, y: 3.7, shade: 0.26)
        box(width: 2.7, length: 0.95, bottom: 0.12, top: 0.85, y: -3.6, shade: 0.26)
        return vertices
    }

    private func outline() -> [Vertex] {
        let points: [SIMD4<Float>] = [SIMD4(-1.30,-5.93,0.25,1), SIMD4(1.30,-5.93,0.25,1), SIMD4(1.30,5.93,0.25,1), SIMD4(-1.30,5.93,0.25,1),
                                     SIMD4(-1.30,-5.93,3.49,1), SIMD4(1.30,-5.93,3.49,1), SIMD4(1.30,5.93,3.49,1), SIMD4(-1.30,5.93,3.49,1)]
        return [[0,1],[1,2],[2,3],[3,0],[4,5],[5,6],[6,7],[7,4],[0,4],[1,5],[2,6],[3,7]].flatMap { pair in
            pair.map { Vertex(position: points[$0], color: SIMD4(0.16,0.42,0.96,1)) }
        }
    }
}

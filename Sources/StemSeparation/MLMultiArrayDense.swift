import CoreML
import Accelerate

extension MLMultiArray {
    /// Copy a dense row-major float array into `self`, honoring its strides.
    func writeDense(_ src: [Float]) throws {
        let shape = shape.map(\.intValue), strides = strides.map(\.intValue)
        let inner = shape.last!, rows = src.count / inner
        withUnsafeMutableBufferPointer(ofType: Float.self) { d, _ in
            src.withUnsafeBufferPointer { s in
                for r in 0..<rows {
                    var off = 0, rem = r
                    for dim in stride(from: shape.count - 2, through: 0, by: -1) {
                        off += (rem % shape[dim]) * strides[dim]
                        rem /= shape[dim]
                    }
                    (d.baseAddress! + off).update(from: s.baseAddress! + r * inner, count: inner)
                }
            }
        }
    }

    /// Read into a dense row-major array (fp32 or fp16, possibly padded strides).
    func readDense(count: Int) throws -> [Float] {
        let shape = shape.map(\.intValue), strides = strides.map(\.intValue)
        let inner = shape.last!, rows = count / inner
        guard shape.reduce(1, *) == count else {
            throw SeparatorError.badModel("unexpected output shape \(shape)")
        }
        var out = [Float](repeating: 0, count: count)
        func offset(_ r: Int) -> Int {
            var off = 0, rem = r
            for dim in stride(from: shape.count - 2, through: 0, by: -1) {
                off += (rem % shape[dim]) * strides[dim]
                rem /= shape[dim]
            }
            return off
        }
        out.withUnsafeMutableBufferPointer { o in
            switch dataType {
            case .float32:
                withUnsafeBufferPointer(ofType: Float.self) { p in
                    for r in 0..<rows { (o.baseAddress! + r * inner).update(from: p.baseAddress! + offset(r), count: inner) }
                }
            case .float16:
                withUnsafeBufferPointer(ofType: Float16.self) { p in
                    for r in 0..<rows {
                        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: p.baseAddress! + offset(r)),
                                                height: 1, width: vImagePixelCount(inner), rowBytes: inner * 2)
                        var dst = vImage_Buffer(data: o.baseAddress! + r * inner, height: 1,
                                                width: vImagePixelCount(inner), rowBytes: inner * 4)
                        vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
                    }
                }
            default:
                break
            }
        }
        return out
    }
}

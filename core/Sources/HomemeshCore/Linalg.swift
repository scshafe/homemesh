import Foundation

public enum Linalg {
    /// Solves the symmetric positive definite system `a x = b` (row-major n x n) by Cholesky; nil when it is not positive definite.
    public static func choleskySolve(_ a: [Double], _ b: [Double], n: Int) -> [Double]? {
        var l = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var sum = a[i * n + j]
                for k in 0..<j { sum -= l[i * n + k] * l[j * n + k] }
                if i == j {
                    if sum <= 1e-12 { return nil }
                    l[i * n + j] = sum.squareRoot()
                } else {
                    l[i * n + j] = sum / l[j * n + j]
                }
            }
        }
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var s = b[i]
            for k in 0..<i { s -= l[i * n + k] * y[k] }
            y[i] = s / l[i * n + i]
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = y[i]
            for k in (i + 1)..<n where k < n { s -= l[k * n + i] * x[k] }
            x[i] = s / l[i * n + i]
        }
        return x
    }
}

import SwiftUI
import CoreImage

/// Cores do app. Mude aqui para trocar o visual inteiro.
enum Theme {
    static let accent = Color(red: 1.00, green: 0.33, blue: 0.42)        // coral
    static let background = Color(red: 0.05, green: 0.05, blue: 0.07)    // quase preto
    static let secondaryText = Color.white.opacity(0.65)
}

private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

extension UIImage {
    /// Cor da capa ajustada para servir de fundo: nem escura nem clara demais.
    var themeTint: UIColor? {
        guard let input = CIImage(image: self),
              let output = CIFilter(name: "CIAreaAverage", parameters: [
                  kCIInputImageKey: input,
                  kCIInputExtentKey: CIVector(cgRect: input.extent),
              ])?.outputImage
        else { return nil }

        var px = [UInt8](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &px, rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: nil)
        let average = UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                              blue: CGFloat(px[2]) / 255, alpha: 1)

        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        average.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return UIColor(hue: h, saturation: min(s * 1.3, 0.85), brightness: min(max(b, 0.30), 0.55), alpha: 1)
    }
}

/// "3 h 12 min", "45 min", "30 s".
func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds)
    let h = total / 3600, m = (total % 3600) / 60
    if h > 0 { return "\(h) h \(m) min" }
    if m > 0 { return "\(m) min" }
    return "\(total) s"
}

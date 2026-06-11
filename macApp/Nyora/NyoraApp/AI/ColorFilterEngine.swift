import Cocoa
import CoreImage

enum ColorFilterEngine {
    /// Caches the processed images to make reader navigation and scrubbing perfectly smooth.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()
    
    static func cachedResult(for image: NSImage, adjustments: ColorAdjustments, cacheKey: String?) -> NSImage? {
        guard !adjustments.isNeutral else { return image }
        guard let key = cacheKey else { return nil }
        let nsKey = "\(key)-\(adjustments.hashValue)" as NSString
        return cache.object(forKey: nsKey)
    }

    static func apply(to image: NSImage, adjustments: ColorAdjustments, cacheKey: String? = nil) async -> NSImage {
        guard !adjustments.isNeutral else { return image }

        // Check cache
        if let key = cacheKey {
            let nsKey = "\(key)-\(adjustments.hashValue)" as NSString
            if let cached = cache.object(forKey: nsKey) {
                return cached
            }
        }

        return await Task.detached(priority: .userInitiated) {
            Self.applySync(to: image, adjustments: adjustments, cacheKey: cacheKey)
        }.value
    }

    private static func applySync(to image: NSImage, adjustments: ColorAdjustments, cacheKey: String?) -> NSImage {
        // Check cache again inside detached task (may have been populated while we were waiting)
        if let key = cacheKey {
            let nsKey = "\(key)-\(adjustments.hashValue)" as NSString
            if let cached = cache.object(forKey: nsKey) {
                return cached
            }
        }

        // Apply adjustments
        guard let tiffData = image.tiffRepresentation,
              let ciImage = CIImage(data: tiffData) else {
            return image
        }
        
        var outputImage = ciImage
        
        // 1. Apply Preset (Duotone/Tritone/etc.)
        if !adjustments.palette.isEmpty, let preset = ColorPreset.by(id: adjustments.palette) {
            if preset.id != "none" {
                // A. Convert to Grayscale (0 saturation) first so grayscale pixels are correctly colorized!
                if let grayscaleFilter = CIFilter(name: "CIColorControls") {
                    grayscaleFilter.setValue(outputImage, forKey: kCIInputImageKey)
                    grayscaleFilter.setValue(0.0, forKey: kCIInputSaturationKey)
                    if let grayscaled = grayscaleFilter.outputImage {
                        outputImage = grayscaled
                    }
                }
                
                // B. Apply preset contrast offset if any
                if preset.contrastOffset != 0 {
                    let scale = preset.contrastOffset + 1.0
                    if let contrastFilter = CIFilter(name: "CIColorControls") {
                        contrastFilter.setValue(outputImage, forKey: kCIInputImageKey)
                        contrastFilter.setValue(scale, forKey: kCIInputContrastKey)
                        if let contrasted = contrastFilter.outputImage {
                            outputImage = contrasted
                        }
                    }
                }
                
                // C. Apply the preset as a luminance gradient map. This is
                // deliberately stronger than the old RGB matrix path: manga
                // pages are mostly tones, so mapping dark/mid/light values
                // through a palette is the reliable way to make presets visible.
                if let filtered = applyGradientMap(to: outputImage, preset: preset) {
                    outputImage = filtered
                }
            }
        }
        
        // 2. Apply Custom Manual Adjustments (if any)
        // Adjustments: Brightness, Contrast, Saturation
        if abs(adjustments.brightness) > 0.001 || abs(adjustments.contrast - 1) > 0.001 || abs(adjustments.saturation - 1) > 0.001 {
            if let colorControls = CIFilter(name: "CIColorControls") {
                colorControls.setValue(outputImage, forKey: kCIInputImageKey)
                colorControls.setValue(adjustments.brightness, forKey: kCIInputBrightnessKey)
                colorControls.setValue(adjustments.contrast, forKey: kCIInputContrastKey)
                colorControls.setValue(adjustments.saturation, forKey: kCIInputSaturationKey)
                if let controlsOutput = colorControls.outputImage {
                    outputImage = controlsOutput
                }
            }
        }
        
        // Hue
        if abs(adjustments.hue) > 0.001 {
            if let hueAdjust = CIFilter(name: "CIHueAdjust") {
                hueAdjust.setValue(outputImage, forKey: kCIInputImageKey)
                let angleRad = adjustments.hue * .pi / 180.0
                hueAdjust.setValue(angleRad, forKey: kCIInputAngleKey)
                if let hueOutput = hueAdjust.outputImage {
                    outputImage = hueOutput
                }
            }
        }
        
        // 3. Render back to NSImage
        let rep = NSCIImageRep(ciImage: outputImage)
        let newNSImage = NSImage(size: rep.size)
        newNSImage.addRepresentation(rep)
        
        // Cache result
        if let key = cacheKey {
            let nsKey = "\(key)-\(adjustments.hashValue)" as NSString
            cache.setObject(newNSImage, forKey: nsKey)
        }
        
        return newNSImage
    }

    private static func applyGradientMap(to image: CIImage, preset: ColorPreset) -> CIImage? {
        let stops = gradientStops(for: preset)
        guard stops.count >= 2, let cubeData = colorCubeData(stops: stops) else { return nil }
        let dimension = 32
        guard let cube = CIFilter(name: "CIColorCube") else { return nil }
        cube.setValue(image, forKey: kCIInputImageKey)
        cube.setValue(dimension, forKey: "inputCubeDimension")
        cube.setValue(cubeData, forKey: "inputCubeData")
        return cube.outputImage
    }

    private static func gradientStops(for preset: ColorPreset) -> [SIMD3<Float>] {
        if let dark = preset.darkColor,
           let light = preset.lightColor,
           dark.count >= 3,
           light.count >= 3 {
            let darkColor = rgb(dark)
            let lightColor = rgb(light)
            return [
                darkColor,
                mix(darkColor, lightColor, t: 0.5),
                lightColor
            ]
        }

        if let matrix = preset.matrixArray, matrix.count == 20 {
            return [0.0, 0.35, 0.68, 1.0].map { luminance in
                matrixColor(matrix, luminance: Float(luminance))
            }
        }

        switch preset.id {
        case "grayscale":
            return [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.5, 0.5, 0.5), SIMD3<Float>(1, 1, 1)]
        case "high-contrast":
            return [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.35, 0.35, 0.35), SIMD3<Float>(1, 1, 1)]
        case "soft":
            return [SIMD3<Float>(0.10, 0.09, 0.08), SIMD3<Float>(0.65, 0.62, 0.58), SIMD3<Float>(1.0, 0.96, 0.90)]
        default:
            return []
        }
    }

    private static func colorCubeData(stops: [SIMD3<Float>]) -> Data? {
        let dimension = 32
        var cube = [Float]()
        cube.reserveCapacity(dimension * dimension * dimension * 4)

        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let r = Float(red) / Float(dimension - 1)
                    let g = Float(green) / Float(dimension - 1)
                    let b = Float(blue) / Float(dimension - 1)
                    let luminance = min(max(0.299 * r + 0.587 * g + 0.114 * b, 0), 1)
                    let color = sampleGradient(stops, luminance: luminance)
                    cube.append(color.x)
                    cube.append(color.y)
                    cube.append(color.z)
                    cube.append(1.0)
                }
            }
        }

        return cube.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    private static func sampleGradient(_ stops: [SIMD3<Float>], luminance: Float) -> SIMD3<Float> {
        guard let first = stops.first else { return SIMD3<Float>(luminance, luminance, luminance) }
        guard stops.count > 1 else { return first }
        let scaled = luminance * Float(stops.count - 1)
        let lower = min(max(Int(floor(scaled)), 0), stops.count - 2)
        let t = scaled - Float(lower)
        return mix(stops[lower], stops[lower + 1], t: t)
    }

    private static func rgb(_ values: [Double]) -> SIMD3<Float> {
        SIMD3<Float>(
            Float(values[0] / 255.0),
            Float(values[1] / 255.0),
            Float(values[2] / 255.0)
        )
    }

    private static func matrixColor(_ matrix: [Double], luminance: Float) -> SIMD3<Float> {
        let l = Double(luminance)
        return SIMD3<Float>(
            Float((matrix[0] * l + matrix[1] * l + matrix[2] * l + matrix[4] / 255.0).clamped(to: 0...1)),
            Float((matrix[5] * l + matrix[6] * l + matrix[7] * l + matrix[9] / 255.0).clamped(to: 0...1)),
            Float((matrix[10] * l + matrix[11] * l + matrix[12] * l + matrix[14] / 255.0).clamped(to: 0...1))
        )
    }

    private static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        a + (b - a) * min(max(t, 0), 1)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

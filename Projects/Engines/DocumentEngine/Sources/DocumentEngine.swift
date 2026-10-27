import ConversionKit

/// Entry point the conversion service uses to register this engine's converters.
public enum DocumentEngine {
    public static let converters: [any Converter.Type] = []
}

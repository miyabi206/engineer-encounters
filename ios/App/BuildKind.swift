public enum BuildKind {
    #if DEVELOPMENT_BUILD
    public static let isDevelopment = true
    #else
    public static let isDevelopment = false
    #endif

    #if INTERNAL_BUILD
    public static let isInternal = true
    #else
    public static let isInternal = false
    #endif
}

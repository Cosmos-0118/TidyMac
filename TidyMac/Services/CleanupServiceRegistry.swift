struct CleanupServiceRegistry {
    static var `default`: [AnyCleanupService] {
        [
            AnyCleanupService(SystemCacheCleanupService()),
            AnyCleanupService(LargeFileScanner()),
            AnyCleanupService(XcodeCacheCleaner())
        ]
    }
}

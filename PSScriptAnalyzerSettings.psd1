@{
    # Rules this project turns off on purpose. Everything else runs.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'                        # interactive installer, console output is the product
        'PSAvoidUsingEmptyCatchBlock'                  # best-effort steps (clipboard, cleanup, error detail parsing) fail silently by design
        'PSUseShouldProcessForStateChangingFunctions'  # internal helpers, not module cmdlets
        'PSUseSingularNouns'                           # Get-InstallSettings and friends read better plural
        'PSAvoidOverwritingBuiltInCmdlets'             # the analyzer's data lists Write-Log as built in; it is not
    )
}

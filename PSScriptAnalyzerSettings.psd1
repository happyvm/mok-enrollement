@{
    IncludeRules = @(
        'PSAvoidDefaultValueSwitchParameter',
        'PSAvoidUsingCmdletAliases',
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingWMICmdlet',
        'PSMisleadingBacktick',
        'PSProvideCommentHelp',
        'PSUseApprovedVerbs',
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSUseLiteralInitializerForHashtable',
        'PSUseShouldProcessForStateChangingFunctions'
    )

    ExcludeRules = @(
        'PSReviewUnusedParameter'
    )

    Rules = @{
        PSProvideCommentHelp = @{
            ExportedOnly = $false
            BlockComment  = $true
            VSCodeSnippetCorrection = $false
            Placement = 'before'
        }
    }
}

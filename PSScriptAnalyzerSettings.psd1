@{
    IncludeRules = @(
        'PSAvoidDefaultValueSwitchParameter',
        'PSAvoidUsingCmdletAliases',
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingWMICmdlet',
        'PSMisleadingBacktick',
        'PSUseApprovedVerbs',
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSUseLiteralInitializerForHashtable',
        'PSUseShouldProcessForStateChangingFunctions'
    )

    ExcludeRules = @(
        'PSReviewUnusedParameter'
    )

    Rules = @{}
}

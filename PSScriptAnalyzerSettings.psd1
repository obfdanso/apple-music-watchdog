@{
    Severity     = @('Error', 'Warning')
    # Manage.ps1's Start-/Stop- helpers are internal; -WhatIf support would just be noise.
    ExcludeRules = @('PSUseShouldProcessForStateChangingFunctions')
}

@{
  IncludeRules = @(
    'PSUseDeclaredVarsMoreThanAssignments'
    'PSUseConsistentIndentation'
    'PSAvoidTrailingWhitespace'
    'PSUseBOMForUnicodeEncodedFile'
    'PSPlaceOpenBrace'
    'PSPlaceCloseBrace'
    'PSUseConsistentWhitespace'
    'PSUseCompatibleSyntax'
  )
  ExcludeRules = @('PSAvoidUsingWriteHost')
  Rules = @{
    PSUseConsistentIndentation = @{
      Enable = $true
      Kind = 'space'
      IndentationSize = 2
    }
    PSPlaceOpenBrace  = @{ Enable = $true; OnSameLine   = $true }
    PSPlaceCloseBrace = @{ Enable = $true; NewLineAfter = $true }
    PSUseCompatibleSyntax = @{
      Enable = $true
      TargetVersions = @('7.4')
    }
  }
}

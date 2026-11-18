param(
    [Parameter(Mandatory = $true)][string]$GodotExe,
    [Parameter(Mandatory = $true)][string]$EditorProject,
    [Parameter(Mandatory = $true)][string]$BirdProject
)

$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()

function Invoke-GodotGate([string]$Project, [string[]]$Args, [string]$Label) {
    Write-Host "=== $Label ==="
    $output = & $GodotExe --headless --path $Project @Args 2>&1
    $code = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }
    $text = ($output | Out-String)
    if ($code -ne 0 -or $text -match '(?m)(SCRIPT ERROR|Parse Error|PARSE_FAIL|_FAIL\b)') {
        $failures.Add("$Label (exit=$code)")
    }
}

$editorGates = @('parse_all', 'regress', 'data_layer_test', 'content_model_test',
                 'content_panel_test', 'def_regression_test', 'entity_copy_regression_test',
                 'props_undo_regression_test', 'shortcut_test', 'portal_mode_regression_test')
foreach ($gate in $editorGates) {
    Invoke-GodotGate $EditorProject @('--script', "res://tests/$gate.gd") "editor/$gate"
}
Invoke-GodotGate $BirdProject @('--script', 'res://tests/parse_bird.gd') 'bird/parse_bird'
Invoke-GodotGate $BirdProject @('res://tests/launch_args_test.tscn') 'bird/launch_args_test'

if ($failures.Count -gt 0) {
    Write-Error ("Gate failures: " + ($failures -join ', '))
    exit 1
}
Write-Host 'ALL_GATES_OK'
exit 0

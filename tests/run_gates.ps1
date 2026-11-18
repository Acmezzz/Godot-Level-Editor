param(
    [Parameter(Mandatory = $true)][string]$GodotExe,
    [Parameter(Mandatory = $true)][string]$EditorProject,
    [Parameter(Mandatory = $true)][string]$BirdProject
)

$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()
# portal_mode_regression_test 以环境变量定位游戏工程——运行器自己补上，免得外部忘设
$env:BIRD_PROJECT = $BirdProject

function Invoke-GodotGate([string]$Project, [string[]]$GateArgs, [string]$Label) {
    Write-Host "=== $Label ==="
    # GUI 子系统 exe：PowerShell 的 `& exe 2>&1` 捕获会让进程静默不启动，
    # 必须走 .NET Process API 显式建管道（实测控制台直通可以、捕获必挂）。
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $GodotExe
    $psi.Arguments = ('--headless --path "{0}" {1}' -f $Project, (($GateArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '))
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $err = $errTask.GetAwaiter().GetResult()
    $p.WaitForExit()
    $code = $p.ExitCode
    $out.Split("`n") | ForEach-Object { Write-Host $_ }
    if ($err.Trim() -ne '') { Write-Host $err }
    if ($code -ne 0 -or ($out + $err) -match '(?m)(SCRIPT ERROR|Parse Error|PARSE_FAIL|_FAIL\b)') {
        $failures.Add("$Label (exit=$code)")
    }
}

$editorGates = @('parse_all', 'regress', 'data_layer_test', 'content_model_test',
                 'def_regression_test', 'entity_copy_regression_test',
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

param(
    [Parameter(Mandatory = $true)][string]$GodotExe,
    [Parameter(Mandatory = $true)][string]$EditorProject
)

$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()

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
                 'props_undo_regression_test', 'shortcut_test')
foreach ($gate in $editorGates) {
    Invoke-GodotGate $EditorProject @('--script', "res://tests/$gate.gd") "editor/$gate"
}

if ($failures.Count -gt 0) {
    Write-Error ("Gate failures: " + ($failures -join ', '))
    exit 1
}
Write-Host 'ALL_GATES_OK'
exit 0

Option Explicit
Dim shell, fso, folder, panelPath, powershellPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
panelPath = fso.BuildPath(folder, "Panel.ps1")
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
If Not fso.FileExists(panelPath) Then
    MsgBox "Panel.ps1 was not found next to this launcher.", vbExclamation, "HWiNFO Desktop Panel"
    WScript.Quit 1
End If
shell.CurrentDirectory = folder
command = Quote(powershellPath) & " -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Quote(panelPath)
On Error Resume Next
shell.Run command, 0, False
If Err.Number <> 0 Then
    MsgBox "Could not start the panel: " & Err.Description, vbExclamation, "HWiNFO Desktop Panel"
    WScript.Quit 1
End If
On Error GoTo 0
Function Quote(value)
    Quote = Chr(34) & value & Chr(34)
End Function

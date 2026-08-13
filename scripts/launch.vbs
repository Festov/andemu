' andemu silent launcher - no console window
' UI text lives in ui-message.ps1 (UTF-8) to avoid VBS codepage issues
Option Explicit

Dim sh, fso, root, emulator, ps, setupScript, startScript, uiScript, rc
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

root = fso.GetParentFolderName(WScript.ScriptFullName)
If LCase(fso.GetFileName(root)) = "scripts" Then
  root = fso.GetParentFolderName(root)
End If

sh.CurrentDirectory = root
emulator = root & "\runtime\android-sdk\emulator\emulator.exe"
ps = "powershell.exe"
setupScript = root & "\scripts\setup.ps1"
startScript = root & "\scripts\start.ps1"
uiScript = root & "\scripts\ui-message.ps1"

Function ShowUi(id, detail, code)
  Dim cmd
  cmd = ps & " -NoProfile -ExecutionPolicy Bypass -File """ & uiScript & """ -Id " & id
  If Len(detail) > 0 Then
    cmd = cmd & " -Detail """ & detail & """"
  End If
  If code <> 0 Then
    cmd = cmd & " -Code " & CStr(code)
  End If
  sh.Run cmd, 1, True
End Function

If Not fso.FileExists(setupScript) Or Not fso.FileExists(startScript) Then
  ShowUi "MissingScripts", root, 0
  WScript.Quit 1
End If

If Not fso.FileExists(uiScript) Then
  MsgBox "Missing scripts\ui-message.ps1 in:" & vbCrLf & root, vbCritical, "andemu"
  WScript.Quit 1
End If

' First-time setup needs a visible PowerShell window
If Not fso.FileExists(emulator) Then
  ShowUi "SetupStart", "", 0
  rc = sh.Run( _
    ps & " -NoProfile -ExecutionPolicy Bypass -File """ & setupScript & """", _
    1, True)
  If rc <> 0 Then
    ShowUi "SetupFailed", "", rc
    WScript.Quit rc
  End If
  If Not fso.FileExists(emulator) Then
    ShowUi "MissingEmulator", "", 0
    WScript.Quit 1
  End If
End If

' Normal start: fully hidden. Errors shown via MessageBox from start.ps1
sh.Environment("Process")("ANDEMU_HIDDEN") = "1"
sh.Run _
  ps & " -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & startScript & """", _
  0, False

WScript.Quit 0

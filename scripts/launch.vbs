' andemu silent launcher — без окна консоли
Option Explicit

Dim sh, fso, root, emulator, ps, setupScript, startScript, rc
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

If Not fso.FileExists(setupScript) Or Not fso.FileExists(startScript) Then
  MsgBox "Не найдены scripts\setup.ps1 / start.ps1 в:" & vbCrLf & root, vbCritical, "andemu"
  WScript.Quit 1
End If

' Первичная установка — нужно видимое окно (скачивание SDK)
If Not fso.FileExists(emulator) Then
  MsgBox "Сейчас будет установка Android runtime (один раз, ~3–6 GB)." & vbCrLf & _
         "После установки эмулятор запустится без окна консоли.", vbInformation, "andemu"
  rc = sh.Run( _
    ps & " -NoProfile -ExecutionPolicy Bypass -File """ & setupScript & """", _
    1, True)
  If rc <> 0 Then
    MsgBox "Ошибка установки (код " & rc & ")." & vbCrLf & _
           "Смотрите logs\setup-latest.log", vbCritical, "andemu"
    WScript.Quit rc
  End If
  If Not fso.FileExists(emulator) Then
    MsgBox "После setup не найден emulator.exe", vbCritical, "andemu"
    WScript.Quit 1
  End If
End If

' Обычный запуск: полностью скрыто (0). Ошибки покажет MessageBox из start.ps1
sh.Environment("Process")("ANDEMU_HIDDEN") = "1"
sh.Run _
  ps & " -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & startScript & """", _
  0, False

WScript.Quit 0

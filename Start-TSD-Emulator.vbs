' Двойной клик сюда — запуск без окна консоли
CreateObject("WScript.Shell").Run _
  "wscript.exe //nologo """ & CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName) & "\scripts\launch.vbs""", _
  0, False

' Double-click to start without a console window
CreateObject("WScript.Shell").Run _
  "wscript.exe //nologo """ & CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName) & "\scripts\launch.vbs""", _
  0, False

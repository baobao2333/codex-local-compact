Set objShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
watchdog = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "proxy-watchdog.ps1")
objShell.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & watchdog & """", 0, False

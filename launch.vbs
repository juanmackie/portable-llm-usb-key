' silent one-click: starts the key with NO console window anywhere
Option Explicit

Dim fso, sh, root, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
root = fso.GetParentFolderName(WScript.ScriptFullName) & "\"

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & root & "scripts\serve.ps1"" start"
sh.Run cmd, 0, False

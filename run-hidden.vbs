' Silent launcher for NvidiaInstantReplayAuto.ps1
'
' Why this file exists:
'   powershell.exe is a console program. Even with -WindowStyle Hidden in a
'   scheduled task, it still flashes a black console window.
'   Launching it through wscript.exe with window style 0 gives a truly
'   invisible start.
'
' This file is intentionally pure ASCII (no BOM, no non-ASCII characters),
' because wscript.exe reads .vbs as ANSI and would choke on UTF-8 text.
'
' It locates the script relative to its own folder, so the whole folder can be
' copied anywhere (other PC, other drive) and still work.

Option Explicit

Dim sh, fso, here, ps, script, cmd

Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' Folder this .vbs lives in -- no hardcoded paths.
here = fso.GetParentFolderName(WScript.ScriptFullName)

ps     = sh.ExpandEnvironmentStrings("%SystemRoot%") & _
         "\System32\WindowsPowerShell\v1.0\powershell.exe"
script = fso.BuildPath(here, "NvidiaInstantReplayAuto.ps1")

If Not fso.FileExists(script) Then
    MsgBox "Cannot find:" & vbCrLf & script, 16, "NvidiaInstantReplayAuto"
    WScript.Quit 1
End If

cmd = """" & ps & """ -NoProfile -ExecutionPolicy Bypass -File """ & script & """"

' 0 = hidden window, False = do not wait for the child process
sh.Run cmd, 0, False

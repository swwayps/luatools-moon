Option Explicit

Dim shell, fso, exePath, exeArgs, command, filePath, fileHandle
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

If WScript.Arguments.Count < 1 Then
  WScript.Quit 1
End If

If LCase(WScript.Arguments(0)) = "/file" Then
  If WScript.Arguments.Count < 2 Then
    WScript.Quit 1
  End If
  filePath = WScript.Arguments(1)
  Set fileHandle = fso.OpenTextFile(filePath, 1, False)
  command = fileHandle.ReadAll
  fileHandle.Close
  shell.Run command, 0, False
  WScript.Quit 0
End If

exePath = WScript.Arguments(0)
exeArgs = ""
If WScript.Arguments.Count > 1 Then
  exeArgs = WScript.Arguments(1)
End If

command = """" & exePath & """ " & exeArgs
shell.Run command, 0, False

Option Explicit

Dim fso, pathValue, parts, current, i
Set fso = CreateObject("Scripting.FileSystemObject")

If WScript.Arguments.Count < 1 Then
  WScript.Quit 1
End If

pathValue = Replace(WScript.Arguments(0), "/", "\")
parts = Split(pathValue, "\")
current = ""

For i = 0 To UBound(parts)
  If parts(i) <> "" Then
    If current = "" Then
      current = parts(i)
    ElseIf Right(current, 1) = "\" Then
      current = current & parts(i)
    Else
      current = current & "\" & parts(i)
    End If

    If Right(current, 1) <> ":" Then
      If Not fso.FolderExists(current) Then
        On Error Resume Next
        fso.CreateFolder(current)
        On Error GoTo 0
      End If
    Else
      current = current & "\"
    End If
  End If
Next

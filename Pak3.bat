set PakName=L_foxBot.pk3
set SzPath="C:\Program Files\7-Zip\7z.exe"

del "%~dp0\%PakName%*"
%SzPath% a -tzip "%~dp0\%PakName%" "%~dp0\pk3\*"

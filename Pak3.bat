set PakName=L_foxBot.pk3
set SzPath="C:\Program Files\7-Zip\7z.exe"

del %PakName%*
%SzPath% a -tzip "%PakName%" "%~dp0\pk3\*"

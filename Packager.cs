using System;
using System.Diagnostics;
using System.IO;

namespace foxBot_SRB2 {
    class Packager {
        static void Main(string[] args) {
            string gamePath = @"D:\Games\Sonic Robo Blast 2\";

            string szPath = @"C:\Program Files\7-Zip\7z.exe";
            string inPath = AppDomain.CurrentDomain.BaseDirectory + @"..\..\..\pk3\*";
            string outPath = gamePath + @"Addons\Self\VL_foxBot.pk3";

            //Package that archive!
            File.Delete(outPath);
            _ = Process.Start(szPath, string.Format("a -tzip \"{0}\" \"{1}\"", outPath, inPath));

            //Run that game!
            _ = Process.Start(
                new ProcessStartInfo(gamePath + "srb2win.exe", string.Format("-file \"{0}\"", outPath)) {
                    WorkingDirectory = gamePath
                }
            );
        }
    }
}

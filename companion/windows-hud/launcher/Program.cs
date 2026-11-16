using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

internal static class Program
{
    [DllImport("user32.dll")]
    private static extern bool AllowSetForegroundWindow(int dwProcessId);

    [STAThread]
    private static int Main(string[] args)
    {
        string exePath = Environment.ProcessPath ?? AppContext.BaseDirectory;
        string baseDir = File.Exists(exePath)
            ? (Path.GetDirectoryName(exePath) ?? AppContext.BaseDirectory)
            : AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

        string hudRoot = baseDir;
        string scriptPath = Path.Combine(hudRoot, "pr-radar-hud.ps1");
        if (!File.Exists(scriptPath))
        {
            string parentDir = Path.GetFullPath(Path.Combine(baseDir, ".."));
            string parentScript = Path.Combine(parentDir, "pr-radar-hud.ps1");
            if (File.Exists(parentScript))
            {
                hudRoot = parentDir;
                scriptPath = parentScript;
            }
            else
            {
                return 2;
            }
        }

        string pwsh = FindPwsh();
        var psi = new ProcessStartInfo
        {
            FileName = pwsh,
            WorkingDirectory = hudRoot,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-ExecutionPolicy");
        psi.ArgumentList.Add("Bypass");
        psi.ArgumentList.Add("-File");
        psi.ArgumentList.Add(scriptPath);

        bool waitForExit = false;
        foreach (string arg in args)
        {
            if (string.Equals(arg, "-Wait", StringComparison.OrdinalIgnoreCase))
            {
                waitForExit = true;
                continue;
            }
            if (string.Equals(arg, "-SavePreview", StringComparison.OrdinalIgnoreCase))
            {
                waitForExit = true;
            }
            psi.ArgumentList.Add(arg);
        }

        AllowSetForegroundWindow(-1);
        using Process? proc = Process.Start(psi);
        if (proc is null)
        {
            return 1;
        }

        AllowSetForegroundWindow(proc.Id);

        if (waitForExit)
        {
            proc.WaitForExit();
            return proc.ExitCode;
        }

        return 0;
    }

    private static string FindPwsh()
    {
        string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string candidate = Path.Combine(pf, "PowerShell", "7", "pwsh.exe");
        if (File.Exists(candidate))
        {
            return candidate;
        }
        return "pwsh.exe";
    }
}

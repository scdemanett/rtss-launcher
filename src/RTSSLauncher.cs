// RTSS Launcher - starts RivaTuner Statistics Server before a game and closes it afterwards.
// Windowless (compiled as /target:winexe). Written for C# 5 so the csc.exe built into Windows
// (.NET Framework 4.x) can compile it on any Windows 10/11 machine.
//
// Usage (Steam launch options):   "C:\Program Files\RTSS Launcher\RTSSLauncher.exe" %command%
// Internal mode (used by the "Stop RTSS" scheduled task):   RTSSLauncher.exe --stop-rtss

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("RTSS Launcher")]
[assembly: System.Reflection.AssemblyProduct("RTSS Launcher")]
[assembly: System.Reflection.AssemblyVersion("1.0.0.0")]
[assembly: System.Reflection.AssemblyFileVersion("1.0.0.0")]
[assembly: System.Reflection.AssemblyInformationalVersion("1.0.0")]

static class RTSSLauncher
{
    const string TaskStart = @"\RTSSLauncher\Start RTSS";
    const string TaskStop = @"\RTSSLauncher\Stop RTSS";

    static readonly string[] RtssProcessNames = { "RTSS", "RTSSHooksLoader64", "RTSSHooksLoader" };

    // Defaults, overridable in [Launcher] section of config.ini next to the exe.
    static int startupDelayMs = 2000;   // after RTSS appears, before starting the game
    static int initialWaitMs = 8000;    // after starting the game, before watching its folder
    static int pollMs = 3000;           // how often to check whether the game is still running
    static int graceMs = 5000;          // re-check after everything closed (launcher -> game handoff)

    static string logPath;

    [STAThread]
    static int Main(string[] argv)
    {
        logPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "RTSSLauncher", "launcher.log");

        try
        {
            if (argv.Length == 1 && string.Equals(argv[0], "--stop-rtss", StringComparison.OrdinalIgnoreCase))
            {
                KillRtss();
                return 0;
            }
            LoadConfig();
            return Run();
        }
        catch (Exception ex)
        {
            Log("ERROR: " + ex);
            return 1;
        }
    }

    // ------------------------------------------------------------------ main flow

    static int Run()
    {
        string exe, args;
        if (!ParseGameCommand(GetArgumentString(), out exe, out args))
        {
            MessageBox.Show(
                "RTSS Launcher needs the game command after it.\n\n" +
                "In Steam: right-click the game > Properties > Launch Options, and enter:\n\n" +
                "\"" + Application.ExecutablePath + "\" %command%",
                "RTSS Launcher", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 2;
        }

        string gameDir = Path.GetDirectoryName(Path.GetFullPath(exe)).TrimEnd('\\') + "\\";
        Log("----");
        Log("Game: " + exe + (args.Length > 0 ? "  args: " + args : ""));
        Log("Watching folder: " + gameDir);

        bool startedByUs = false;
        if (IsRtssRunning())
        {
            Log("RTSS already running - will leave it open afterwards.");
        }
        else
        {
            Log("Starting RTSS via scheduled task.");
            RunTask(TaskStart);
            WaitUntil(IsRtssRunning, 15000);
            if (IsRtssRunning())
            {
                startedByUs = true;
                Thread.Sleep(startupDelayMs);
            }
            else
            {
                Log("WARNING: RTSS did not start. Launching the game anyway.");
            }
        }

        ProcessStartInfo psi = new ProcessStartInfo(exe, args);
        psi.UseShellExecute = true;          // honours compatibility settings on the game exe
        psi.WorkingDirectory = gameDir;
        Process.Start(psi);
        Log("Game started.");

        Thread.Sleep(initialWaitMs);
        do
        {
            while (AnyProcessInFolder(gameDir)) Thread.Sleep(pollMs);
            Thread.Sleep(graceMs);
        } while (AnyProcessInFolder(gameDir));
        Log("Game closed.");

        if (startedByUs)
        {
            Log("Stopping RTSS via scheduled task.");
            RunTask(TaskStop);
        }
        return 0;
    }

    // ------------------------------------------------------------------ RTSS control

    static bool IsRtssRunning()
    {
        Process[] procs = Process.GetProcessesByName("RTSS");
        bool running = procs.Length > 0;
        foreach (Process p in procs) p.Dispose();
        return running;
    }

    // Runs elevated (from the "Stop RTSS" task), so it can terminate the elevated RTSS.
    static void KillRtss()
    {
        foreach (string name in RtssProcessNames)
        {
            foreach (Process p in Process.GetProcessesByName(name))
            {
                try { p.Kill(); p.WaitForExit(5000); }
                catch (Exception ex) { Log("Could not stop " + name + ": " + ex.Message); }
                finally { p.Dispose(); }
            }
        }
    }

    static void RunTask(string taskName)
    {
        ProcessStartInfo psi = new ProcessStartInfo(
            Path.Combine(Environment.SystemDirectory, "schtasks.exe"),
            "/run /tn \"" + taskName + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;

        using (Process p = Process.Start(psi))
        {
            string output = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
            p.WaitForExit(15000);
            if (p.ExitCode != 0)
                Log("schtasks failed for '" + taskName + "' (exit " + p.ExitCode + "): " + output.Trim() +
                    "  -> re-run Install.cmd");
        }
    }

    // ------------------------------------------------------------------ process watching

    const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool QueryFullProcessImageName(IntPtr hProcess, int flags, StringBuilder exeName, ref int size);

    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    // Limited-information queries work even for elevated processes, so a game set to
    // "Run as administrator" is still seen.
    static string GetProcessPath(int pid)
    {
        IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (h == IntPtr.Zero) return null;
        try
        {
            StringBuilder sb = new StringBuilder(1024);
            int size = sb.Capacity;
            return QueryFullProcessImageName(h, 0, sb, ref size) ? sb.ToString() : null;
        }
        finally { CloseHandle(h); }
    }

    static bool AnyProcessInFolder(string folder)
    {
        int self = Process.GetCurrentProcess().Id;
        foreach (Process p in Process.GetProcesses())
        {
            int pid = p.Id;
            p.Dispose();
            if (pid <= 4 || pid == self) continue;
            string path = GetProcessPath(pid);
            if (path != null && path.StartsWith(folder, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    static void WaitUntil(Func<bool> condition, int timeoutMs)
    {
        Stopwatch sw = Stopwatch.StartNew();
        while (!condition() && sw.ElapsedMilliseconds < timeoutMs) Thread.Sleep(250);
    }

    // ------------------------------------------------------------------ command line

    // Everything after our own exe on the raw command line, quoting preserved.
    static string GetArgumentString()
    {
        string cmd = Environment.CommandLine.TrimStart();
        int end;
        if (cmd.StartsWith("\""))
        {
            end = cmd.IndexOf('"', 1);
            end = end < 0 ? cmd.Length : end + 1;
        }
        else
        {
            end = cmd.IndexOf(' ');
            if (end < 0) end = cmd.Length;
        }
        return cmd.Substring(end).Trim();
    }

    static bool ParseGameCommand(string rest, out string exe, out string args)
    {
        exe = null;
        args = "";
        if (string.IsNullOrEmpty(rest)) return false;

        if (rest.StartsWith("\""))
        {
            int close = rest.IndexOf('"', 1);
            if (close < 0) { exe = rest.Trim('"'); }
            else { exe = rest.Substring(1, close - 1); args = rest.Substring(close + 1).Trim(); }
        }
        else
        {
            // Unquoted path that may contain spaces: take the shortest prefix that is an existing file.
            exe = rest;
            for (int i = rest.IndexOf(' '); i >= 0; i = rest.IndexOf(' ', i + 1))
            {
                string candidate = rest.Substring(0, i);
                if (File.Exists(candidate))
                {
                    exe = candidate;
                    args = rest.Substring(i + 1).Trim();
                    break;
                }
            }
        }

        if (!File.Exists(exe))
        {
            Log("Game executable not found: " + exe);
            return false;
        }
        return true;
    }

    // ------------------------------------------------------------------ config + log

    static void LoadConfig()
    {
        string ini = Path.Combine(Path.GetDirectoryName(Application.ExecutablePath), "config.ini");
        if (!File.Exists(ini)) return;

        string section = "";
        foreach (string raw in File.ReadAllLines(ini))
        {
            string line = raw.Trim();
            if (line.Length == 0 || line.StartsWith(";") || line.StartsWith("#")) continue;
            if (line.StartsWith("[") && line.EndsWith("]")) { section = line.Substring(1, line.Length - 2).Trim(); continue; }
            if (!string.Equals(section, "Launcher", StringComparison.OrdinalIgnoreCase)) continue;

            int eq = line.IndexOf('=');
            if (eq < 0) continue;
            string key = line.Substring(0, eq).Trim();
            int value;
            if (!int.TryParse(line.Substring(eq + 1).Trim(), out value) || value < 0) continue;

            switch (key.ToLowerInvariant())
            {
                case "startupdelayms": startupDelayMs = value; break;
                case "initialwaitms": initialWaitMs = value; break;
                case "pollms": pollMs = Math.Max(500, value); break;
                case "gracems": graceMs = value; break;
            }
        }
    }

    static void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(logPath));
            FileInfo fi = new FileInfo(logPath);
            if (fi.Exists && fi.Length > 256 * 1024) fi.Delete();
            File.AppendAllText(logPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + message + Environment.NewLine);
        }
        catch { }
    }
}

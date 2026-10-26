using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("HomeRemote")]
[assembly: AssemblyDescription("HomeRemote — управление домашним удалённым доступом")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.1.0")]

internal static class Program {
    // Replaced by the build script with the hash of the embedded runtime.
    private const string BuildId = "RUNTIME_BUILD_ID";
    private static readonly string[] Files = {
        "HomeRemote.ps1", "HomeRemote.xaml", "HomeRemote-Backend.ps1",
        "Remote-Toggle.ps1", "HomeRemote-Certificates.ps1", "HomeRemote-EasyRSA.sh"
    };

    [STAThread]
    private static int Main(string[] args) {
        Application.EnableVisualStyles();
        try {
            string dataRoot = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            string appFolder = Path.Combine(dataRoot, "Application");
            PrepareDirectory(appFolder);
            string runtime = Path.Combine(appFolder, BuildId);
            PrepareDirectory(runtime);
            foreach (string file in Files) ExtractVerified(runtime, file);

            List<string> options = ParseOptions(args);
            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string powershell = Path.Combine(windows, @"System32\WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powershell)) throw new FileNotFoundException("Не найден Windows PowerShell 5.1.", powershell);
            StringBuilder arguments = new StringBuilder("-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File ");
            arguments.Append(Quote(Path.Combine(runtime, "HomeRemote.ps1")));
            arguments.Append(" -DataRoot ").Append(Quote(dataRoot));
            foreach (string option in options) arguments.Append(' ').Append(Quote(option));
            ProcessStartInfo start = new ProcessStartInfo(powershell, arguments.ToString());
            start.WorkingDirectory = dataRoot;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.WindowStyle = ProcessWindowStyle.Hidden;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            using (Process process = Process.Start(start)) {
                var output = process.StandardOutput.ReadToEndAsync();
                var error = process.StandardError.ReadToEndAsync();
                process.WaitForExit();
                string errorText = error.Result.Trim();
                if (process.ExitCode != 0) {
                    string detail = errorText.Length == 0 ? output.Result.Trim() : errorText;
                    if (detail.Length > 5000) detail = detail.Substring(0, 5000);
                    throw new InvalidOperationException("Не удалось запустить HomeRemote.\r\n\r\n" + detail);
                }
                return 0;
            }
        } catch (Exception error) {
            MessageBox.Show(error.Message, "HomeRemote", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static List<string> ParseOptions(string[] args) {
        List<string> result = new List<string>();
        for (int i = 0; i < args.Length; i++) {
            string arg = args[i].ToLowerInvariant();
            switch (arg) {
                case "--preview": result.Add("-Preview"); break;
                case "--smoke-test": result.Add("-SmokeTest"); break;
                case "--smoke-exit-failure": result.Add("-SmokeExitFailure"); break;
                case "--capture-path":
                case "--smoke-log":
                    if (++i >= args.Length) throw new ArgumentException("Не указан путь: " + arg);
                    result.Add(arg == "--capture-path" ? "-CapturePath" : "-SmokeLog");
                    result.Add(Path.GetFullPath(args[i]));
                    break;
                default: throw new ArgumentException("Неизвестный параметр: " + args[i]);
            }
        }
        return result;
    }

    private static void PrepareDirectory(string path) {
        if (Directory.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Служебная папка не должна быть ссылкой: " + path);
        Directory.CreateDirectory(path);
        DirectorySecurity acl = new DirectorySecurity();
        acl.SetAccessRuleProtection(true, false);
        SecurityIdentifier user = WindowsIdentity.GetCurrent().User;
        acl.SetOwner(user);
        foreach (SecurityIdentifier sid in new[] { user,
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null) }) {
            acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                PropagationFlags.None, AccessControlType.Allow));
        }
        Directory.SetAccessControl(path, acl);
    }

    private static byte[] Resource(string file) {
        using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("HomeRemote.Runtime." + file)) {
            if (source == null) throw new IOException("Отсутствует компонент приложения: " + file);
            using (MemoryStream buffer = new MemoryStream()) {
                source.CopyTo(buffer);
                return buffer.ToArray();
            }
        }
    }

    private static string Hash(byte[] bytes) {
        using (SHA256 sha = SHA256.Create()) return Convert.ToBase64String(sha.ComputeHash(bytes));
    }

    private static void ExtractVerified(string directory, string file) {
        string destination = Path.Combine(directory, file);
        byte[] embedded = Resource(file);
        if (File.Exists(destination)) {
            if ((File.GetAttributes(destination) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Компонент приложения не должен быть ссылкой: " + file);
            if (Hash(File.ReadAllBytes(destination)) == Hash(embedded)) return;
            throw new IOException("Компонент приложения изменён: " + destination + "\r\nУдалите эту служебную папку Application после закрытия приложения и запустите EXE повторно.");
        }
        string temporary = Path.Combine(directory, ".component-" + Guid.NewGuid().ToString("N"));
        try {
            File.WriteAllBytes(temporary, embedded);
            try { File.Move(temporary, destination); }
            catch (IOException) {
                // Another launch may have extracted the identical resource first.
                if (!File.Exists(destination) || Hash(File.ReadAllBytes(destination)) != Hash(embedded)) throw;
            }
        } finally { if (File.Exists(temporary)) File.Delete(temporary); }
        if (Hash(File.ReadAllBytes(destination)) != Hash(embedded)) throw new IOException("Ошибка проверки компонента: " + file);
    }

    private static string Quote(string value) {
        StringBuilder result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char ch in value) {
            if (ch == '\\') { slashes++; continue; }
            if (ch == '"') result.Append('\\', slashes * 2 + 1).Append(ch);
            else result.Append('\\', slashes).Append(ch);
            slashes = 0;
        }
        result.Append('\\', slashes * 2).Append('"');
        return result.ToString();
    }
}

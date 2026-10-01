using System;
using System.IO;
using System.IO.Compression;
using System.Diagnostics;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Drawing;

class Gateway : Form {
    readonly TextBox domain = new TextBox { Width=350 };
    string Domain { get { return domain.Text.Trim().ToLowerInvariant(); } }
    static bool ValidDomain(string value) {
        if(value.Length<3 || value.Length>253 || value.IndexOf('.')<0 || Uri.CheckHostName(value)!=UriHostNameType.Dns) return false;
        foreach(string label in value.Split('.')) {
            if(label.Length<1 || label.Length>63 || label.StartsWith("-") || label.EndsWith("-")) return false;
            foreach(char ch in label) if(!((ch>='a' && ch<='z') || (ch>='0' && ch<='9') || ch=='-')) return false;
        }
        return true;
    }
    const string PayloadHash = "PAYLOAD_HASH";
    readonly string root = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "HTCommander-Gateway-Data");
    TextBox log = new TextBox(); Label status = new Label(); Button start = new Button(); Button stop = new Button();
    Process child; bool closing;
    NumericUpDown port = new NumericUpDown { Minimum=1024,Maximum=65535,Value=18080,Width=85 };
    static string Hash(string path) { using(var s=File.OpenRead(path)) using(var h=SHA256.Create()) return BitConverter.ToString(h.ComputeHash(s)).Replace("-", "").ToLowerInvariant(); }
    string Prepare() {
        if(!ValidDomain(Domain)) throw new Exception("请填写有效域名，例如 radio.example.com；不含 https://、端口或路径。 / Enter a DNS hostname only.");
        Directory.CreateDirectory(root);
        string exe = Path.Combine(root,"caddy.exe");
        if(!File.Exists(exe) || Hash(exe)!=PayloadHash) {
            string temp=exe+".tmp";
            using(var src=Assembly.GetExecutingAssembly().GetManifestResourceStream("caddy.gz"))
            using(var zip=new GZipStream(src,CompressionMode.Decompress))
            using(var dest=File.Create(temp)) zip.CopyTo(dest);
            if(Hash(temp)!=PayloadHash) throw new Exception("内置 Caddy 校验失败。");
            if(File.Exists(exe)) File.Delete(exe);
            File.Move(temp,exe);
        }
        string storage=Path.Combine(root,"certificates").Replace("\\","/");
        File.WriteAllText(Path.Combine(root,"backend-port.txt"),port.Value.ToString());
        File.WriteAllText(Path.Combine(root,"gateway-domain.txt"),Domain);
        File.WriteAllText(Path.Combine(root,"Caddyfile"), "{\n    storage file_system {\n        root \""+storage+"\"\n    }\n}\n"+Domain+" {\n    reverse_proxy 127.0.0.1:"+port.Value+" {\n        header_up Host "+Domain+"\n        header_down Referrer-Policy same-origin\n    }\n}\n",new UTF8Encoding(false));
        return exe;
    }
    void Append(string s) {
        if(String.IsNullOrEmpty(s)) return;
        try { File.AppendAllText(Path.Combine(root,"gateway.log"),DateTime.Now.ToString("s")+" "+s+Environment.NewLine,Encoding.UTF8); } catch {}
        if(closing || IsDisposed) return;
        if(InvokeRequired) { try { BeginInvoke((Action)(()=>Display(s))); } catch {} } else Display(s);
    }
    void Display(string s) { if(log.TextLength>80000) log.Clear(); log.AppendText(s+Environment.NewLine); }
    void StartGateway() {
        if(child!=null && !child.HasExited) return;
        try {
            string exe=Prepare();
            child=new Process(); child.StartInfo=new ProcessStartInfo(exe,"run --config Caddyfile --adapter caddyfile") {
                WorkingDirectory=root, UseShellExecute=false,CreateNoWindow=true,RedirectStandardError=true,RedirectStandardOutput=true
            };
            child.EnableRaisingEvents=true;
            child.OutputDataReceived+=(s,e)=>Append(e.Data); child.ErrorDataReceived+=(s,e)=>Append(e.Data);
            child.Exited+=(s,e)=> { if(!closing && IsHandleCreated) try { BeginInvoke((Action)(()=> { status.Text="HTTPS 进程已停止，请检查日志。"; start.Enabled=true; stop.Enabled=false; port.Enabled=true;domain.Enabled=true; })); } catch {} };
            child.Start(); child.BeginOutputReadLine(); child.BeginErrorReadLine();
            status.Text="HTTPS 进程运行中；证书与外网连通性请查看日志并用手机验证。";
            start.Enabled=false; stop.Enabled=true; port.Enabled=false;domain.Enabled=false;
            Append("启动入口 https://"+Domain+" → 127.0.0.1:"+port.Value);
        } catch(Exception ex) { Append(ex.Message); status.Text="启动失败："+ex.Message; start.Enabled=true; stop.Enabled=false; port.Enabled=true;domain.Enabled=true; }
    }
    void StopGateway() {
        try { if(child!=null && !child.HasExited) { child.Kill(); child.WaitForExit(3000); } } catch(Exception ex) { Append(ex.Message); }
        if(child!=null) { child.Dispose(); child=null; }
        if(!closing) { status.Text="已停止 HTTPS 入口。"; start.Enabled=true; stop.Enabled=false;port.Enabled=true;domain.Enabled=true; }
    }
    static void Open(string target) { Process.Start(new ProcessStartInfo(target) { UseShellExecute=true }); }
    public Gateway() {
        Text="HTCommander HTTPS Gateway"; ClientSize=new Size(850,650); MinimumSize=new Size(800,620);
        try { int saved; if(Int32.TryParse(File.ReadAllText(Path.Combine(root,"backend-port.txt")),out saved) && saved>=1024 && saved<=65535) port.Value=saved; }catch {}
        try { domain.Text=File.ReadAllText(Path.Combine(root,"gateway-domain.txt")).Trim(); }catch {}
        Font=new Font("Microsoft YaHei UI",10); StartPosition=FormStartPosition.CenterScreen;
        var layout=new TableLayoutPanel { Dock=DockStyle.Fill, Padding=new Padding(16),ColumnCount=1,RowCount=5 };
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute,80)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute,118));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute,80)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute,42));layout.RowStyles.Add(new RowStyle(SizeType.Percent,100));
        var settings=new FlowLayoutPanel { Dock=DockStyle.Fill };
        settings.Controls.Add(new Label { Text="公网域名 / Domain",AutoSize=true,Padding=new Padding(0,6,0,0) });settings.Controls.Add(domain);
        settings.Controls.Add(new Label { Text="填写自己的域名，例如 radio.example.com",AutoSize=true });layout.Controls.Add(settings,0,0);
        layout.Controls.Add(new Label { Dock=DockStyle.Fill, Text="1. 域名 A / AAAA 记录指向电台电脑可达的公网地址。\n2. IPv4 路由器映射 TCP 80/443；IPv6 放行入站防火墙。\n3. HTCommander 开启远程网页服务，端口与下方一致，设置密码；\n   外网 HTTPS 地址填写 https://你的域名。\n关闭窗口将停止入口；程序不修改防火墙或发射权限。 / See configuration guide." },0,1);
        var buttons=new FlowLayoutPanel { Dock=DockStyle.Fill };
        buttons.Controls.Add(new Label { Text="后端端口",AutoSize=true,Padding=new Padding(0,6,0,0) });buttons.Controls.Add(port);
        start.Text="启动入口"; stop.Text="停止入口"; stop.Enabled=false;
        start.AutoSize=stop.AutoSize=true; start.Click+=(s,e)=>StartGateway(); stop.Click+=(s,e)=>StopGateway(); buttons.Controls.Add(start);buttons.Controls.Add(stop);
        var visit=new Button { Text="打开访问地址",AutoSize=true };visit.Click+=(s,e)=>Open("https://"+Domain);buttons.Controls.Add(visit);
        var copy=new Button { Text="复制 HTTPS 地址",AutoSize=true };copy.Click+=(s,e)=>Clipboard.SetText("https://"+Domain);buttons.Controls.Add(copy);
        var logs=new Button { Text="打开数据目录",AutoSize=true };logs.Click+=(s,e)=> { Directory.CreateDirectory(root); Open(root); };buttons.Controls.Add(logs);
        layout.Controls.Add(buttons,0,2);status.Dock=DockStyle.Fill;status.Text="填写域名和后端端口，点击启动入口。";layout.Controls.Add(status,0,3);
        log.Multiline=true; log.ReadOnly=true;log.ScrollBars=ScrollBars.Both;log.WordWrap=false;log.Dock=DockStyle.Fill;log.Font=new Font("Consolas",9);layout.Controls.Add(log,0,4);Controls.Add(layout);
        FormClosing+=(s,e)=> { closing=true;StopGateway(); };
    }
    [STAThread] static int Main(string[] args) {
        using(var mutex=new Mutex(false,"Local\\HTCommander-HTTPS-Gateway"+(args.Length>0 && args[0]=="--self-test" ? "-SelfTest-"+Process.GetCurrentProcess().Id : ""))) {
            bool acquired=false;try { acquired=mutex.WaitOne(0); }catch(AbandonedMutexException) { acquired=true; }
            if(!acquired) { MessageBox.Show("入口程序已经运行，请使用已有窗口。");return 1; }
            try {
                Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
                using(var form=new Gateway()) {
                    if(args.Length>0 && args[0]=="--self-test") {
                        if(ValidDomain("https://radio.example.com") || ValidDomain("evil.example\n}") || ValidDomain("127.0.0.1") || !ValidDomain("radio.example.com")) return 2;
                        form.domain.Text="radio.example.com";
                        form.port.Value=18080;
                        string exe=form.Prepare();
                        var p=Process.Start(new ProcessStartInfo(exe,"adapt --config Caddyfile --adapter caddyfile") { WorkingDirectory=form.root,UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true });
                        string output=p.StandardOutput.ReadToEnd();string error=p.StandardError.ReadToEnd();p.WaitForExit();
                        File.WriteAllText(Path.Combine(form.root,"self-test.txt"),"Embedded SHA256: "+Hash(exe)+"\n"+output+"\n"+error);
                        int code=p.ExitCode;p.Dispose();return code;
                    }
                    Application.Run(form);
                }
                return 0;
            } finally { mutex.ReleaseMutex(); }
        }
    }
}

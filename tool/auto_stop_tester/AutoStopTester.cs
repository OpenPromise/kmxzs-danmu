using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace AutoStopTest
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length > 0 && args[0] == "--self-test")
                return SelfTest.Run();
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
            return 0;
        }
    }

    internal static class SelfTest
    {
        public static int Run()
        {
            var server = new TestStreamServer(19090);
            try
            {
                server.Start();
                using (var client = new TcpClient())
                {
                    client.Connect(IPAddress.Loopback, 19090);
                    client.ReceiveTimeout = 3000;
                    NetworkStream stream = client.GetStream();
                    byte[] request = Encoding.ASCII.GetBytes(
                        "GET /auto-stop-test-live-stream.flv HTTP/1.1\r\n" +
                        "Host: 127.0.0.1\r\nConnection: close\r\n\r\n");
                    stream.Write(request, 0, request.Length);
                    var received = new MemoryStream();
                    var buffer = new byte[4096];
                    while (received.Length < 256)
                    {
                        int count = stream.Read(buffer, 0, buffer.Length);
                        if (count <= 0) return 11;
                        received.Write(buffer, 0, count);
                    }
                    byte[] first = received.ToArray();
                    string text = Encoding.ASCII.GetString(first);
                    if (text.IndexOf("HTTP/1.1 200 OK", StringComparison.Ordinal) < 0)
                        return 12;
                    if (!ContainsFlvHeader(first)) return 13;

                    server.SetLive(false);
                    bool disconnected = false;
                    try
                    {
                        while (stream.Read(buffer, 0, buffer.Length) > 0) { }
                        disconnected = true;
                    }
                    catch (IOException)
                    {
                        disconnected = true;
                    }
                    catch (SocketException)
                    {
                        disconnected = true;
                    }
                    if (!disconnected) return 14;
                }
                return 0;
            }
            catch
            {
                return 20;
            }
            finally
            {
                server.Dispose();
            }
        }

        private static bool ContainsFlvHeader(byte[] data)
        {
            for (int i = 0; i + 2 < data.Length; i++)
            {
                if (data[i] == (byte)'F' && data[i + 1] == (byte)'L' &&
                    data[i + 2] == (byte)'V') return true;
            }
            return false;
        }
    }

    internal sealed class MainForm : Form
    {
        private const string TestUrl =
            "http://127.0.0.1:19090/auto-stop-test-live-stream.flv";

        private readonly TestStreamServer _server = new TestStreamServer(19090);
        private readonly Label _state = new Label();
        private readonly Label _clients = new Label();
        private readonly Button _resume = new Button();
        private readonly Button _cut = new Button();

        public MainForm()
        {
            Text = "自动关播断流测试工具";
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(650, 410);
            MinimumSize = new Size(666, 449);
            Font = new Font("Microsoft YaHei UI", 10F);
            BackColor = Color.FromArgb(246, 248, 252);
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);

            var title = new Label();
            title.Text = "自动关播断流测试";
            title.Font = new Font(Font.FontFamily, 18F, FontStyle.Bold);
            title.AutoSize = true;
            title.Location = new Point(28, 22);
            Controls.Add(title);

            var hint = new Label();
            hint.Text = "用内置测试画面模拟直播流；断流后等待约 18–25 秒观察是否自动关播。";
            hint.ForeColor = Color.FromArgb(75, 85, 99);
            hint.AutoSize = true;
            hint.Location = new Point(31, 66);
            Controls.Add(hint);

            var urlLabel = new Label();
            urlLabel.Text = "客户端直播间地址";
            urlLabel.AutoSize = true;
            urlLabel.Location = new Point(31, 108);
            Controls.Add(urlLabel);

            var url = new TextBox();
            url.Text = TestUrl;
            url.ReadOnly = true;
            url.Location = new Point(34, 135);
            url.Size = new Size(480, 28);
            Controls.Add(url);

            var copy = new Button();
            copy.Text = "复制地址";
            copy.Location = new Point(526, 133);
            copy.Size = new Size(92, 32);
            copy.Click += delegate
            {
                Clipboard.SetText(TestUrl);
                MessageBox.Show(this, "测试地址已复制。", "提示",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
            };
            Controls.Add(copy);

            _state.AutoSize = true;
            _state.Font = new Font(Font.FontFamily, 12F, FontStyle.Bold);
            _state.Location = new Point(31, 190);
            Controls.Add(_state);

            _clients.AutoSize = true;
            _clients.ForeColor = Color.FromArgb(75, 85, 99);
            _clients.Location = new Point(31, 222);
            Controls.Add(_clients);

            _resume.Text = "开始 / 恢复供流";
            _resume.Size = new Size(270, 58);
            _resume.Location = new Point(34, 258);
            _resume.BackColor = Color.FromArgb(22, 163, 74);
            _resume.ForeColor = Color.White;
            _resume.FlatStyle = FlatStyle.Flat;
            _resume.Click += delegate { _server.SetLive(true); };
            Controls.Add(_resume);

            _cut.Text = "立即断流";
            _cut.Size = new Size(270, 58);
            _cut.Location = new Point(348, 258);
            _cut.BackColor = Color.FromArgb(220, 38, 38);
            _cut.ForeColor = Color.White;
            _cut.FlatStyle = FlatStyle.Flat;
            _cut.Click += delegate { _server.SetLive(false); };
            Controls.Add(_cut);

            var steps = new Label();
            steps.Text =
                "使用：复制地址 → 粘贴到快马小助手 → 开启“源直播结束后自动关播” " +
                "→ 一键开播 → 看到测试画面后点击“立即断流”。";
            steps.ForeColor = Color.FromArgb(55, 65, 81);
            steps.Location = new Point(31, 338);
            steps.Size = new Size(590, 50);
            Controls.Add(steps);

            _server.Changed += OnServerChanged;
            Shown += delegate
            {
                try
                {
                    _server.Start();
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this,
                        "无法启动本地测试流：" + ex.Message +
                        "\r\n请确认 19090 端口未被其它程序占用。",
                        "启动失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            };
            FormClosing += delegate { _server.Dispose(); };
            UpdateState(true, 0, "测试流服务已启动");
        }

        private void OnServerChanged(bool live, int clients, string message)
        {
            if (IsDisposed) return;
            if (InvokeRequired)
            {
                BeginInvoke(new Action<bool, int, string>(UpdateState),
                    live, clients, message);
                return;
            }
            UpdateState(live, clients, message);
        }

        private void UpdateState(bool live, int clients, string message)
        {
            _state.Text = live ? "● 正在供流" : "● 已断流";
            _state.ForeColor = live
                ? Color.FromArgb(22, 163, 74)
                : Color.FromArgb(220, 38, 38);
            _clients.Text = string.Format("OBS 连接数：{0}    {1}", clients, message);
            _resume.Enabled = !live;
            _cut.Enabled = live;
        }
    }

    internal sealed class FlvTag
    {
        public readonly byte[] Bytes;
        public readonly uint Timestamp;

        public FlvTag(byte[] bytes, uint timestamp)
        {
            Bytes = bytes;
            Timestamp = timestamp;
        }
    }

    internal sealed class TestStreamServer : IDisposable
    {
        private readonly int _port;
        private readonly object _sync = new object();
        private readonly List<TcpClient> _clients = new List<TcpClient>();
        private readonly byte[] _flvHeader;
        private readonly List<FlvTag> _tags;
        private readonly uint _clipDuration;
        private TcpListener _listener;
        private volatile bool _running;
        private volatile bool _live = true;

        public event Action<bool, int, string> Changed;

        public TestStreamServer(int port)
        {
            byte[] data;
            _port = port;
            using (Stream input = Assembly.GetExecutingAssembly()
                .GetManifestResourceStream("AutoStopTest.sample.flv"))
            {
                if (input == null) throw new InvalidOperationException("内置测试视频缺失");
                using (var memory = new MemoryStream())
                {
                    input.CopyTo(memory);
                    data = memory.ToArray();
                }
            }
            ParseFlv(data, out _flvHeader, out _tags, out _clipDuration);
        }

        public void Start()
        {
            if (_running) return;
            _listener = new TcpListener(IPAddress.Loopback, _port);
            _listener.Start();
            _running = true;
            Task.Run((Action)AcceptLoop);
            Notify("等待 OBS 连接");
        }

        public void SetLive(bool live)
        {
            _live = live;
            if (!live)
            {
                TcpClient[] current;
                lock (_sync) current = _clients.ToArray();
                foreach (TcpClient client in current)
                {
                    try { client.Client.LingerState = new LingerOption(true, 0); }
                    catch { }
                    try { client.Close(); }
                    catch { }
                }
                Notify("连接已主动切断，请等待客户端判定结束");
            }
            else
            {
                Notify("测试流已恢复，OBS 可重新连接");
            }
        }

        private void AcceptLoop()
        {
            while (_running)
            {
                try
                {
                    TcpClient client = _listener.AcceptTcpClient();
                    Task.Run(() => Serve(client));
                }
                catch
                {
                    if (_running) Notify("接受连接失败");
                }
            }
        }

        private void Serve(TcpClient client)
        {
            lock (_sync) _clients.Add(client);
            Notify("OBS 已连接测试流");
            try
            {
                client.NoDelay = true;
                client.ReceiveTimeout = 5000;
                client.SendTimeout = 5000;
                NetworkStream stream = client.GetStream();
                string request = ReadRequest(stream);
                bool expectedPath = request.IndexOf(
                    "GET /auto-stop-test-live-stream.flv", StringComparison.Ordinal) >= 0;
                if (!expectedPath)
                {
                    WriteText(stream, "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
                    return;
                }
                if (!_live)
                {
                    WriteText(stream,
                        "HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nRetry-After: 2\r\n\r\n");
                    return;
                }

                WriteText(stream,
                    "HTTP/1.1 200 OK\r\n" +
                    "Content-Type: video/x-flv\r\n" +
                    "Cache-Control: no-store, no-cache\r\n" +
                    "Access-Control-Allow-Origin: *\r\n" +
                    "Connection: close\r\n\r\n");
                stream.Write(_flvHeader, 0, _flvHeader.Length);
                stream.Flush();

                var clock = Stopwatch.StartNew();
                ulong loopBase = 0;
                while (_running && _live && client.Connected)
                {
                    foreach (FlvTag tag in _tags)
                    {
                        if (!_running || !_live) return;
                        ulong timestamp = loopBase + tag.Timestamp;
                        while ((ulong)clock.ElapsedMilliseconds + 8 < timestamp)
                        {
                            Thread.Sleep(5);
                            if (!_running || !_live) return;
                        }
                        byte[] bytes = (byte[])tag.Bytes.Clone();
                        uint stamp = (uint)(timestamp & 0xffffffff);
                        bytes[4] = (byte)((stamp >> 16) & 0xff);
                        bytes[5] = (byte)((stamp >> 8) & 0xff);
                        bytes[6] = (byte)(stamp & 0xff);
                        bytes[7] = (byte)((stamp >> 24) & 0xff);
                        stream.Write(bytes, 0, bytes.Length);
                    }
                    stream.Flush();
                    loopBase += _clipDuration;
                }
            }
            catch
            {
                // OBS 断开或用户点击断流时属于正常结束。
            }
            finally
            {
                try { client.Close(); }
                catch { }
                lock (_sync) _clients.Remove(client);
                Notify(_live ? "等待 OBS 连接" : "当前保持断流状态");
            }
        }

        private static string ReadRequest(NetworkStream stream)
        {
            var bytes = new List<byte>();
            var one = new byte[1];
            while (bytes.Count < 8192)
            {
                int read = stream.Read(one, 0, 1);
                if (read <= 0) break;
                bytes.Add(one[0]);
                int count = bytes.Count;
                if (count >= 4 && bytes[count - 4] == 13 && bytes[count - 3] == 10 &&
                    bytes[count - 2] == 13 && bytes[count - 1] == 10) break;
            }
            return Encoding.ASCII.GetString(bytes.ToArray());
        }

        private static void WriteText(Stream stream, string value)
        {
            byte[] data = Encoding.ASCII.GetBytes(value);
            stream.Write(data, 0, data.Length);
            stream.Flush();
        }

        private void Notify(string message)
        {
            Action<bool, int, string> handler = Changed;
            if (handler == null) return;
            int count;
            lock (_sync) count = _clients.Count;
            handler(_live, count, message);
        }

        private static void ParseFlv(byte[] data, out byte[] header,
            out List<FlvTag> tags, out uint duration)
        {
            if (data.Length < 13 || data[0] != (byte)'F' ||
                data[1] != (byte)'L' || data[2] != (byte)'V')
                throw new InvalidDataException("内置测试视频不是有效 FLV");

            int headerSize = (data[5] << 24) | (data[6] << 16) |
                (data[7] << 8) | data[8];
            int position = headerSize + 4;
            header = new byte[position];
            Buffer.BlockCopy(data, 0, header, 0, position);
            tags = new List<FlvTag>();
            uint maxTimestamp = 0;

            while (position + 15 <= data.Length)
            {
                int dataSize = (data[position + 1] << 16) |
                    (data[position + 2] << 8) | data[position + 3];
                int total = 11 + dataSize + 4;
                if (position + total > data.Length) break;
                uint timestamp = (uint)((data[position + 7] << 24) |
                    (data[position + 4] << 16) |
                    (data[position + 5] << 8) | data[position + 6]);
                byte[] tag = new byte[total];
                Buffer.BlockCopy(data, position, tag, 0, total);
                tags.Add(new FlvTag(tag, timestamp));
                if (timestamp > maxTimestamp) maxTimestamp = timestamp;
                position += total;
            }
            if (tags.Count == 0) throw new InvalidDataException("内置 FLV 没有媒体帧");
            duration = Math.Max(1000U, maxTimestamp + 100U);
        }

        public void Dispose()
        {
            _running = false;
            SetLive(false);
            try { if (_listener != null) _listener.Stop(); }
            catch { }
        }
    }
}

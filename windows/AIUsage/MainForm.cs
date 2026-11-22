using System.ComponentModel;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using static AIUsage.L10n;

namespace AIUsage;

/// Codex 펫처럼 늘 다른 창 위에 떠 있는 작은 창. 눌러도 지금 쓰는 프로그램의 초점을 뺏지 않고,
/// 작업 표시줄 단추로 켜고 끈다(오른쪽 클릭 → 창 닫기).
sealed class MainForm : Form
{
    // 96 DPI 기준 픽셀. S() 로 화면 배율을 곱한다.
    const int BaseWidth = 300, PadX = 12, PadY = 10, HeaderH = 18, RowH = 16, Gap = 5, SectionGap = 9;
    const int PercentW = 72, ResetW = 82, ColGap = 8, BarH = 5, DotSize = 8;
    /// 「5시간」「주간」 칸 너비 — 영어(Weekly)는 조금 넓게
    static int LabelW => L10n.Current == "en" ? 44 : 34;
    const TextFormatFlags TextFlags = TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix;

    readonly UsageHistory history = new();
    readonly LimitAlerts alerts = new();
    readonly NotifyIcon notification = new();
    readonly System.Windows.Forms.Timer balloonTimer = new() { Interval = 12_000 };
    SourceScan scanned = new();
    UsageAccount? activeUser;
    TrendForm? trend;
    bool scanning, rescanOnRefresh;
    readonly BalloonPresenter balloons;
    bool showModels = Settings.Read(Settings.ShowModelLimits) == 1;
    bool modelAlerts = Settings.Read(Settings.ModelLimitAlerts) == 1;
    // 창에 보일 칸(오른쪽 클릭 「Claude 보이기」「ChatGPT 보이기」, 맥판과 같다). 둘 중 하나는 꼭 남는다
    bool showClaude = Settings.Read(Settings.ShowClaude) == 1 || Settings.Read(Settings.ShowCodex) == 0;
    bool showCodex = Settings.Read(Settings.ShowCodex) == 1;
    /// 켜 둔 Claude·ChatGPT 칸을 고른 순서대로(작업 표시줄 게이지·사용 추이가 쓴다)
    Pane[] Panes => order.Where(p => p == Pane.Claude ? showClaude : p == Pane.Codex && showCodex).ToArray();
    /// 떠 있는 창에 그릴 칸: 고른 순서대로, 켜 둔 칸만(세션은 열린 세션이 있을 때만) — 맥판과 같다
    List<Pane> ShownPanes => order.Where(p => p switch
    {
        Pane.Sessions => SessionRows > 0,
        Pane.Codex => showCodex,
        _ => showClaude,
    }).ToList();

    List<UsageEvent> LiveRows() => UsageEvent.LiveRows(claudeSnap,codex);

    void SyncUsage(bool allowScan = true)
    {
        var n = DateTimeOffset.Now.ToUnixTimeMilliseconds();
        var user = UsageAccount.Read(n);
        var changed = user != activeUser;
        activeUser = user;
        if (Settings.LimitAlerts)
        {
            // 숨긴 칸은 알리지 않는다(맥판과 같다): 기다리던 초기화 알림도 지운다
            if (!showClaude) alerts.Cancel("claude");
            if (!showCodex) alerts.Cancel("codex");
        }
        history.RecordLive(LiveRows(),user,n);
        if (trend != null)
        {
            trend.SetData(TrendResult.Calculate(history.VisibleRows,user,n),n,Panes);
            if (allowScan && (changed || rescanOnRefresh)) ScanHistory();
        }
        SendAlert();
    }

    async void ScanHistory(bool retryAccountChange = true)
    {
        if (scanning) return;
        scanning = true;
        rescanOnRefresh = false;
        bool accountChanged = false;
        var n = DateTimeOffset.Now.ToUnixTimeMilliseconds();
        var user = UsageAccount.Read(n);
        var next = scanned.Copy();
        try
        {
            var rows = await Task.Run(() => next.Read(user,n));
            if (IsDisposed) return;
            n = DateTimeOffset.Now.ToUnixTimeMilliseconds();
            accountChanged = UsageAccount.Read(n) != user;
            if (!accountChanged && history.Merge(rows,n)) scanned = next;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        finally { scanning = false; }
        if (IsDisposed || trend == null) return;
        SyncUsage(allowScan: false);
        if (accountChanged || activeUser != user)
        {
            if (retryAccountChange) ScanHistory(retryAccountChange: false);
            else rescanOnRefresh = true;
        }
    }
    void OpenTrend()
    {
        if (trend == null)
        {
            trend = new TrendForm();
            trend.FormClosed += (_,_) => trend = null;
            trend.Show();
        }
        if (trend.WindowState == FormWindowState.Minimized) trend.WindowState = FormWindowState.Normal;
        trend.Activate();
        SyncUsage();
        ScanHistory();
    }
    void EndBalloon()
    {
        if (!balloons.Dismiss()) return;
        balloonTimer.Stop();
        SendAlert();
    }
    void SendAlert()
    {
        if (IsDisposed) return;
        var enabled = Settings.LimitAlerts;
        if (balloons.Busy)
        {
            alerts.ApplyPreferences(enabled, modelAlerts);
            return;
        }
        var n = DateTimeOffset.Now.ToUnixTimeMilliseconds();
        var c = alerts.NextLive(claudeSnap, codex, n, enabled, modelAlerts, provider => provider == "claude" ? showClaude : showCodex);
        if (c == null) return;
        if (!Settings.LimitAlerts || (c.Notice.Model != null && !modelAlerts) ||
            UsageAccount.Read(n).Keys().GetValueOrDefault(c.Notice.Provider) != c.Notice.Account) return;
        var before = alerts.State;
        if (!alerts.Save(c.State)) return;
        try
        {
            balloons.Show(c.Notice);
            balloonTimer.Start();
        }
        catch (Exception e) when (e is InvalidOperationException or Win32Exception or ArgumentException)
        {
            alerts.Save(before);
        }
    }
    void ToggleAlerts()
    {
        Settings.LimitAlerts = !Settings.LimitAlerts;
        if (Settings.LimitAlerts) SendAlert();
        else { alerts.Cancel(); balloonTimer.Stop(); balloons.Dismiss(); }
    }

    void ToggleModelAlerts()
    {
        if (!Settings.LimitAlerts) return;
        modelAlerts = Settings.Save(Settings.ModelLimitAlerts, modelAlerts ? 0 : 1, modelAlerts ? 1 : 0) == 1;
        SendAlert();
    }

    void SetShown(bool claudeOn, bool codexOn)
    {
        if (!claudeOn && !codexOn) return;  // 둘 다 끄면 빈 창이 되므로 하나는 남긴다
        var codexTurnedOn = codexOn && !showCodex;
        showClaude = Settings.Save(Settings.ShowClaude, claudeOn ? 1 : 0, showClaude ? 1 : 0) == 1;
        showCodex = Settings.Save(Settings.ShowCodex, codexOn ? 1 : 0, showCodex ? 1 : 0) == 1;
        if (!showClaude && !showCodex) showClaude = true;
        if (!showClaude) alerts.Cancel("claude");
        if (!showCodex) alerts.Cancel("codex");
        SyncUsage();
        if (codexTurnedOn) RefreshServer();
        FitSize();
        Redraw();
    }

    void ToggleModelDisplay()
    {
        showModels = Settings.Save(Settings.ShowModelLimits, showModels ? 0 : 1, showModels ? 1 : 0) == 1;
        FitSize();
        Redraw();
    }

    readonly Mutex mutex;
    readonly bool afterInstall;
    readonly ClaudeReader claude = new();
    readonly CodexReader codex = new();
    readonly System.Windows.Forms.Timer localTimer = new() { Interval = 15_000 };
    readonly System.Windows.Forms.Timer serverTimer = new() { Interval = 300_000 };
    readonly System.Windows.Forms.Timer updateTimer = new() { Interval = (int)Updater.FirstDelay.TotalMilliseconds };
    // Claude Code 가 응답하면(대화 기록이 바뀌면) 곧 `claude /usage` 를 묻고, 그 밖에는 5분마다 — 5초마다 때인지 본다
    readonly System.Windows.Forms.Timer usageTimer = new() { Interval = 5_000 };
    readonly ClaudeActivityWatcher activity = new();
    readonly ContextMenuStrip menu = new();
    ProviderSnapshot claudeSnap = new(), codexSnap = new();
    Pane[] order = Settings.Order;
    DateTimeOffset now = DateTimeOffset.Now;
    DateTimeOffset? usageAskedAt;
    HashSet<string> measuredNames = new(StringComparer.Ordinal);
    bool fetching, updating, useRegion, askingUsage;
    Font? fontName, fontSmall, fontRow, fontPercent;

    int backgroundLevel = Settings.Read(Settings.Background);
    int windowPercent = Settings.Read(Settings.WindowSize);
    int textPercent = Settings.Read(Settings.TextSize);
    int savedBackground;
    bool layeredFailed, dragging, wasMinimized;
    Point? anchor;
    int labelWidth, percentWidth, resetWidth;

    // 표시 방식 「작업 표시줄 (간단 모드)」: 알림 영역 왼쪽의 동그란 게이지. 붙일 수 없으면 떠 있는 창을 대신 보인다
    int displayMode = Settings.Read(Settings.DisplayMode);
    int taskbarSize = Settings.Read(Settings.TaskbarSize);
    TaskbarGauge? gauge;
    string? taskbarProblem, taskbarLogged;
    int taskbarFailures;
    readonly System.Windows.Forms.Timer taskbarTimer = new() { Interval = 1_000 };
    readonly NativeWindow menuAnchor = new();

    // 세션(떠 있는 창 맨 위 칸·작업 표시줄 위 패널): 3초마다 읽고, 작업 중인 게 보이면 고리를 돌린다
    readonly SessionReader sessionReader = new();
    List<AgentSession> sessions = [];
    readonly System.Windows.Forms.Timer sessionTimer = new() { Interval = 3_000 };
    readonly System.Windows.Forms.Timer spinTimer = new() { Interval = 120 };
    float spin;
    bool showSessions = Settings.Read(Settings.ShowSessions) == 1;
    // 칸 접기(머리줄을 누르면 접고 펴고, 기억한다): 세션은 머리줄에 개수만, Claude·ChatGPT 는 주간 게이지와 % 한 줄
    bool sessionsFolded = Settings.Read(Settings.FoldSessions) == 1;
    bool claudeFolded = Settings.Read(Settings.FoldClaude) == 1;
    bool codexFolded = Settings.Read(Settings.FoldCodex) == 1;
    readonly List<(Rectangle Row, string Pane)> headerHits = [];
    SessionPopup? popup;
    readonly List<(Rectangle Row, AgentSession Session)> sessionHits = [];
    readonly System.Windows.Forms.Timer rightTimer = new() { Interval = SystemInformation.DoubleClickTime };
    Point rightAt;

    public MainForm(Mutex mutex, bool afterInstall)
    {
        savedBackground = backgroundLevel;
        this.mutex = mutex;
        this.afterInstall = afterInstall;
        Text = T("AI 사용량");
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = true;
        TopMost = true;
        MaximizeBox = false;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        BackColor = Palette.Background;
        DoubleBuffered = true;
        if (Installer.LoadIcon() is { } icon) Icon = icon;
        notification.Icon = Icon ?? SystemIcons.Application;
        balloons = new BalloonPresenter(visible => notification.Visible = visible,
            notice => notification.ShowBalloonTip(10_000,notice.Title,notice.Body ?? " ",ToolTipIcon.Info));
        notification.BalloonTipClosed += (_,_) => EndBalloon();
        balloonTimer.Tick += (_,_) => EndBalloon();
        menu.Opening += OnMenuOpening;
        MouseDown += OnMouseDownDrag;
        // 오른쪽 클릭: 한 번이면(두 번째가 안 오면) 메뉴, 두 번이면 작업 표시줄로
        MouseUp += (_, e) =>
        {
            if (e.Button != MouseButtons.Right) return;
            if (rightTimer.Enabled)
            {
                rightTimer.Stop();
                BeginInvoke(new Action(() => ChooseAppearance(Settings.DisplayMode, 1)));
            }
            else
            {
                rightAt = Cursor.Position;
                rightTimer.Start();
            }
        };
        rightTimer.Tick += (_, _) =>
        {
            rightTimer.Stop();
            ShowMenuAt(rightAt);
        };
        // 세션 줄 위에서는 손가락 커서(누르면 그 대화를 연다)
        MouseMove += (_, e) => HoverSession(e.Location);
        MouseLeave += (_, _) => HoverSession(null);
        localTimer.Tick += (_, _) => RefreshLocal();
        serverTimer.Tick += (_, _) => RefreshServer();
        usageTimer.Tick += (_, _) => CheckClaudeUsage();
        taskbarTimer.Tick += (_, _) => SyncTaskbar();
        sessionTimer.Tick += (_, _) => ReadSessions();
        spinTimer.Tick += (_, _) => Spin();
        updateTimer.Tick += (_, _) =>
        {
            updateTimer.Interval = (int)Updater.Interval.TotalMilliseconds;  // 처음은 켠 뒤 1분, 그 뒤 6시간마다
            CheckForUpdate(manual: false);
        };
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x08000000 | 0x00040000;  // WS_EX_NOACTIVATE(초점 안 뺏음) | WS_EX_APPWINDOW(작업 표시줄 단추)
            if (backgroundLevel != 0) cp.ExStyle |= 0x00080000; // WS_EX_LAYERED
            cp.ClassStyle |= 0x00020000;            // CS_DROPSHADOW(그림자)
            return cp;
        }
    }

    protected override bool ShowWithoutActivation => true;

    protected override void OnLoad(EventArgs e)
    {
        base.OnLoad(e);
        MakeFonts();
        ClaudeLink.RepairIfBroken();
        RefreshLocal();
        PlaceWindow(reset: false);
        ApplyCorners();
        Redraw();
        localTimer.Start();
        serverTimer.Start();
        updateTimer.Start();
        usageTimer.Start();
        taskbarTimer.Start();
        ReadSessions();
        sessionTimer.Start();
        BeginInvoke(new Action(SyncTaskbar));
        RefreshServer();
        CheckClaudeUsage();
        if (afterInstall) BeginInvoke(new Action(() => ClaudeLink.Ask(fromMenu: false)));
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
        localTimer.Dispose();
        serverTimer.Dispose();
        updateTimer.Dispose();
        usageTimer.Dispose();
        taskbarTimer.Dispose();
        DropGauge();
        menuAnchor.DestroyHandle();
        sessionTimer.Dispose();
        spinTimer.Dispose();
        popup?.Dispose();
        rightTimer.Dispose();
        activity.Dispose();
        balloonTimer.Dispose(); notification.Dispose(); trend?.Close();
        foreach (var font in new[] { fontName, fontSmall, fontRow, fontPercent }) font?.Dispose();
        base.OnFormClosed(e);
    }

    // MARK: 자동 업데이트

    /// 새 판이 있으면 받아서 그 exe 에 바꾸기를 맡기고 이 창은 닫는다(새 판이 다시 띄운다).
    /// 자동 확인은 조용히 하고, 메뉴에서 누른 확인만 결과를 알린다.
    async void CheckForUpdate(bool manual)
    {
        if (updating) return;
        if (!Installer.IsInstalled)
        {
            if (manual)
                MessageBox.Show(T("설치한 뒤에 업데이트할 수 있습니다.\n창 오른쪽 클릭 → 「설치(시작 메뉴에 등록)」"), T("AI 사용량"),
                                MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        if (!manual && !Settings.AutoUpdate) return;
        updating = true;
        try
        {
            Updater.CleanUp();
            var release = await Updater.LatestAsync();
            if (IsDisposed) return;
            if (release is null || Updater.Compare(release.Version, Updater.Current) <= 0)
            {
                Updater.Log($"확인: 최신(올라온 최신 {release?.Version ?? "없음"})");
                if (manual)
                    MessageBox.Show(T("최신 버전입니다") + "\n\n" + T("지금 {0}", Updater.Current) + (release is null ? "" : " " + T("· 올라온 최신 {0}", release.Version)),
                                    T("AI 사용량"), MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            Updater.Log($"새 판 {release.Version} 받기 시작");
            var exe = await Updater.DownloadAsync(release);
            if (IsDisposed) return;
            Updater.Launch(exe);
            Close();
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or IOException or UnauthorizedAccessException
                                      or InvalidDataException or System.Text.Json.JsonException or Win32Exception)
        {
            Updater.Log($"실패: {e.Message}");
            if (manual && !IsDisposed)
                MessageBox.Show(T("업데이트하지 못했습니다") + "\n\n" + e.Message, T("AI 사용량"), MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally
        {
            updating = false;
        }
    }

    // MARK: 값

    void RefreshLocal()
    {
        now = DateTimeOffset.Now;
        claudeSnap = claude.Read(now);
        var codexSwitched = codex.ReadLog(now);
        codexSnap = codex.Current;
        SyncUsage();
        FitSize();
        Redraw();
        if (codexSwitched) RefreshServer();  // ChatGPT 계정이 바뀌었다: 5분 기다리지 않고 새 계정 값을 묻는다
    }

    async void RefreshServer(bool retry = true)
    {
        if (fetching || !showCodex) return;  // ChatGPT 칸을 껐으면 codex 를 띄우지 않는다
        fetching = true;
        try
        {
            var owner = CodexReader.CurrentAccount();
            var result = await Task.Run(CodexReader.FetchServerAsync);
            if (IsDisposed) return;
            if (!codex.ApplyServer(result,owner))
            {
                codexSnap = codex.Current;
                SyncUsage();
                FitSize();
                Redraw();
                if (retry) BeginInvoke(new Action(() => RefreshServer(false)));
                return;
            }
        }
        finally
        {
            fetching = false;
        }
        if (IsDisposed) return;
        codexSnap = codex.Current;
        SyncUsage();
        FitSize();
        Redraw();
    }

    void RefreshAll()
    {
        RefreshLocal();
        RefreshServer();
        AskClaudeUsage("새로고침");
    }

    /// 지금 `claude /usage` 를 물을 때인지 본다(처음·Claude Code 응답 직후·5분마다)
    void CheckClaudeUsage()
    {
        if (!showClaude || ClaudeUsageCommand.DisabledReason() != null) return;  // Claude 칸을 껐으면 묻지 않는다
        activity.Ensure();
        if (ClaudeActivityWatcher.Due(DateTimeOffset.Now, usageAskedAt, activity.Pending()) is { } reason) AskClaudeUsage(reason);
    }

    async void AskClaudeUsage(string reason)
    {
        if (askingUsage || !showClaude || ClaudeUsageCommand.DisabledReason() != null) return;
        askingUsage = true;
        usageAskedAt = DateTimeOffset.Now;
        activity.Take();
        try
        {
            await Task.Run(() => ClaudeUsageCommand.FetchAsync(reason));
        }
        finally
        {
            askingUsage = false;
        }
        if (!IsDisposed) RefreshLocal();
    }

    void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Resume && IsHandleCreated) BeginInvoke(new Action(RefreshAll));  // 절전에서 깨면 바로 새로
    }

    // MARK: 크기·위치

    int S(double value) => (int)Math.Round(value * DeviceDpi / 96.0);

    int Content(double points) => S(points * windowPercent / 100);
    int TextSize(double points) => Content(points * textPercent / 100);
    int DividerHeight => windowPercent == 100 ? 1 : Math.Max(1, Content(1));
    int HeaderHeight => TextSize(HeaderH);
    int RowHeight => TextSize(RowH);

    int Rows(ProviderSnapshot snap)
    {
        int count = snap.VisibleWindows(showModels).Count();
        return count == 0 ? 2 : count;
    }
    bool Folded(ProviderSnapshot snap) => snap == claudeSnap ? claudeFolded : codexFolded;
    int SectionHeight(ProviderSnapshot snap) => Folded(snap) ? HeaderHeight : HeaderHeight + Rows(snap) * (Content(Gap) + RowHeight);
    /// 세션 칸 줄 수(끄거나 세션이 없으면 0 — 칸이 없어진다). 8개가 넘으면 7줄 + 「외 N개」
    int SessionRows => !showSessions ? 0 : Math.Min(sessions.Count, SessionRow.MaxRows);
    int SessionsHeight => SessionRows == 0 ? 0 : HeaderHeight + (sessionsFolded ? 0 : SessionRows * (Content(Gap) + RowHeight));
    int PaneHeight(Pane pane) => pane switch
    {
        Pane.Sessions => SessionsHeight,
        Pane.Codex => SectionHeight(codexSnap),
        _ => SectionHeight(claudeSnap),
    };

    void FitSize()
    {
        if (WindowState == FormWindowState.Minimized || fontName == null) return;
        MeasureColumns();
        int width = Content(BaseWidth) + labelWidth - Content(LabelW)
            + percentWidth - Content(PercentW) + resetWidth - Content(ResetW);
        var panes = ShownPanes;
        var size = new Size(width, Content(PadY) * 2 + panes.Sum(PaneHeight)
            + Math.Max(0, panes.Count - 1) * (Content(SectionGap) * 2 + DividerHeight));
        bool resized = size != Size;
        var location = Location;
        if (!dragging && anchor is Point point)
        {
            var probe = new Point(point.X + S(10), point.Y + S(10));
            var area = Screen.FromPoint(probe).WorkingArea;
            location = new Point(Math.Max(area.Left, Math.Min(point.X, area.Right - size.Width)),
                Math.Max(area.Top, Math.Min(point.Y, area.Bottom - size.Height)));
        }
        var bounds = new Rectangle(location, size);
        if (Bounds != bounds) Bounds = bounds;
        if (resized && useRegion) ApplyRegion();
    }

    void PlaceWindow(bool reset)
    {
        if (reset) Settings.ClearPosition();
        if (!reset && Settings.LoadPosition() is { } saved
            && Screen.AllScreens.Any(s => s.WorkingArea.Contains(saved.X + S(10), saved.Y + S(10))))
            anchor = saved;
        else
        {
            var area = (Screen.PrimaryScreen ?? Screen.AllScreens[0]).WorkingArea;
            anchor = new Point(area.Right - Width - S(16), area.Top + S(16));
        }
        FitSize();
    }

    void OnDisplaySettingsChanged(object? sender, EventArgs e)
    {
        if (IsHandleCreated) BeginInvoke(new Action(() => { FitSize(); Redraw(); }));
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        if (fontName != null)
        {
            MakeFonts();
            FitSize();
            Redraw();
        }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        if (fontName != null)
            BeginInvoke(new Action(() =>
            {
                if (!IsHandleCreated || IsDisposed) return;
                ApplyCorners();
                FitSize();
                Redraw();
            }));
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        bool restored = wasMinimized && WindowState != FormWindowState.Minimized;
        wasMinimized = WindowState == FormWindowState.Minimized;
        if (restored) { FitSize(); Redraw(); }
    }

    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    void OnMouseDownDrag(object? sender, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left || e.Clicks > 1) return;
        var start = Location;
        var pointer = Cursor.Position;
        dragging = true;
        try
        {
            ReleaseCapture();
            SendMessage(Handle, 0xA1, 2, IntPtr.Zero); // WM_NCLBUTTONDOWN + HTCAPTION, returns on release
        }
        finally { dragging = false; }
        if (Location != start && Cursor.Position != pointer)
        {
            anchor = Location;
            Settings.SavePosition(Location);
        }
        else if (HeaderAt(PointToClient(Cursor.Position)) is { } pane)
            ToggleFold(pane);  // 머리줄: 접고 편다
        else if (SessionAt(PointToClient(Cursor.Position)) is { } session)
            SessionOpener.Open(session);  // 끌지 않고 눌렀다 뗐으면: 세션 줄이면 그 대화를 연다
        FitSize();
    }

    void ApplyCorners()
    {
        if (backgroundLevel != 0)
        {
            useRegion = false;
            Region = null;
            int square = 1, noBorder = unchecked((int)0xfffffffe);
            DwmSetWindowAttribute(Handle, 33, ref square, sizeof(int));
            DwmSetWindowAttribute(Handle, 34, ref noBorder, sizeof(int));
            return;
        }
        var round = 2;  // DWMWCP_ROUND: Windows 11 은 모서리를 부드럽게 둥글린다
        useRegion = DwmSetWindowAttribute(Handle, 33, ref round, sizeof(int)) != 0;  // Windows 10 은 직접 깎는다
        var border = ColorTranslator.ToWin32(Palette.Background);  // Windows 11 의 밝은 테두리 대신 배경색
        DwmSetWindowAttribute(Handle, 34, ref border, sizeof(int));
        if (useRegion) ApplyRegion();
    }

    void ApplyRegion()
    {
        using var path = Rounded(new RectangleF(0, 0, Width, Height), Content(10));
        Region = new Region(path);
    }

    static GraphicsPath Rounded(RectangleF r, float radius)
    {
        var d = radius * 2;
        var path = new GraphicsPath();
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    // MARK: 그리기

    void MakeFonts()
    {
        foreach (var font in new[] { fontName, fontSmall, fontRow, fontPercent }) font?.Dispose();
        const string face = "Malgun Gothic";
        fontName = new Font(face, TextSize(13), FontStyle.Bold, GraphicsUnit.Pixel);
        fontSmall = new Font(face, TextSize(11), FontStyle.Regular, GraphicsUnit.Pixel);
        fontRow = new Font(face, TextSize(12), FontStyle.Regular, GraphicsUnit.Pixel);
        fontPercent = new Font(face, TextSize(12), FontStyle.Bold, GraphicsUnit.Pixel);
        MeasureColumns(force: true);
    }

    static StringFormat LayerTextFormat(TextFormatFlags flags)
    {
        using var template = StringFormat.GenericTypographic;
        var format = (StringFormat)template.Clone();
        format.Alignment = flags.HasFlag(TextFormatFlags.Right) ? StringAlignment.Far
            : flags.HasFlag(TextFormatFlags.HorizontalCenter) ? StringAlignment.Center : StringAlignment.Near;
        format.LineAlignment = flags.HasFlag(TextFormatFlags.VerticalCenter) ? StringAlignment.Center : StringAlignment.Near;
        format.FormatFlags &= ~(StringFormatFlags.NoClip | StringFormatFlags.NoWrap);
        if (flags.HasFlag(TextFormatFlags.SingleLine)) format.FormatFlags |= StringFormatFlags.NoWrap;
        format.Trimming = flags.HasFlag(TextFormatFlags.EndEllipsis) ? StringTrimming.EllipsisCharacter : StringTrimming.None;
        return format;
    }

    static int MeasureLayerText(Graphics g, string text, Font font)
    {
        using var format = LayerTextFormat(TextFlags);
        return (int)Math.Ceiling(g.MeasureString(text, font, PointF.Empty, format).Width);
    }

    void MeasureColumns(bool force = false)
    {
        var names = (showClaude ? claudeSnap.VisibleWindows(showModels) : []).Concat(showCodex ? codexSnap.VisibleWindows(showModels) : [])
            .Select(w => w.Label).ToHashSet(StringComparer.Ordinal);
        if (!force && measuredNames.SetEquals(names)) return;
        measuredNames = names;
        using var g = CreateGraphics();
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        int Column(int nominal, Font font, IEnumerable<string> samples)
        {
            int width = TextSize(nominal);
            foreach (var text in samples)
            {
                int gdi = TextRenderer.MeasureText(g, text, font, Size.Empty, TextFlags).Width;
                width = Math.Max(width, Math.Max(gdi, MeasureLayerText(g, text, font)));
            }
            return width;
        }
        var baseline = Column(LabelW, fontRow!, [T("5시간"), T("주간")]);
        var visibleWidth = names.Count == 0 ? 0 : Column(0, fontRow!, names) + TextSize(2);
        labelWidth = Math.Clamp(visibleWidth, baseline, baseline + TextSize(64));
        percentWidth = Column(PercentW, fontPercent!, [T("{0}% 남음", 100)]);
        var resets = L10n.Culture.DateTimeFormat.AbbreviatedDayNames.Select(day => $"↺ {day} 23:59");
        resetWidth = Column(ResetW, fontSmall!, resets.Append("↺ 12/31").Append(T("초기화됨")));
    }

    int MeasureText(Graphics g, string text, Font font) => backgroundLevel == 0
        ? TextRenderer.MeasureText(g, text, font, Size.Empty, TextFlags).Width : MeasureLayerText(g, text, font);

    void DrawText(Graphics g, string text, Font font, Rectangle rect, Color color, TextFormatFlags flags)
    {
        if (rect.Width <= 0) return;
        if (backgroundLevel == 0)
        {
            TextRenderer.DrawText(g, text, font, rect, color, flags);
            return;
        }
        using var format = LayerTextFormat(flags);
        if (backgroundLevel == 3)
        {
            var shadow = rect;
            shadow.Offset(0, Math.Max(1, Content(1)));
            using var shade = new SolidBrush(Color.FromArgb(150, Color.Black));
            g.DrawString(text, font, shade, shadow, format);
        }
        using var brush = new SolidBrush(color);
        g.DrawString(text, font, brush, rect, format);
    }

    /// gauge: 작업 표시줄 게이지에도 새 값을 넘긴다(고리만 돌릴 때는 넘기지 않는다)
    void Redraw(bool gauge = true)
    {
        if (gauge) PushGauge();
        if (!IsHandleCreated || IsDisposed || anchor == null || fontName == null || WindowState == FormWindowState.Minimized) return;
        if (backgroundLevel != 0)
        {
            byte alpha = backgroundLevel switch { 1 => 179, 2 => 122, _ => 66 };
            var sample = new Point(Width / 2, Content(PadY) / 2);
            if (LayeredSurface.Present(Handle, Size, sample, alpha, g =>
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                using var brush = new SolidBrush(Color.FromArgb(alpha, Palette.Background));
                using var path = Rounded(new RectangleF(0, 0, Width, Height), Content(10));
                g.FillPath(brush, path);
                DrawContent(g);
            })) return;

            layeredFailed = true;
            backgroundLevel = 0; // Keep the registry preference for the next launch.
            UpdateStyles();
            ApplyCorners();
        }
        Invalidate();
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        if (backgroundLevel == 0) base.OnPaintBackground(e);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        if (backgroundLevel == 0 && fontName != null) DrawContent(e.Graphics);
    }

    void DrawContent(Graphics g)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var y = Content(PadY);
        sessionHits.Clear();
        headerHits.Clear();
        var panes = ShownPanes;
        for (var i = 0; i < panes.Count; i++)  // 고른 순서대로(「칸 순서」 메뉴, 세션 칸도 자리를 바꿀 수 있다), 켜 둔 칸만, 칸 사이에 구분선
        {
            if (i > 0)
            {
                y += Content(SectionGap);
                using (var pen = new Pen(Palette.Divider, DividerHeight)) g.DrawLine(pen, Content(PadX), y, Width - Content(PadX), y);
                y += DividerHeight + Content(SectionGap);
            }
            switch (panes[i])
            {
                case Pane.Sessions:
                    y = DrawSessions(g, y);
                    break;
                case Pane.Codex:
                    var detail = string.Join(" · ", new[] { "Codex", codexSnap.Plan }.Where(s => !string.IsNullOrEmpty(s)));
                    y = DrawSection(g, "ChatGPT", detail, Palette.ChatGPT, codexSnap, y);
                    break;
                default:
                    y = DrawSection(g, "Claude", null, Palette.Claude, claudeSnap, y);
                    break;
            }
        }
    }

    int DrawSection(Graphics g, string name, string? detail, Color dot, ProviderSnapshot snap, int top)
    {
        int left = Content(PadX), right = Width - Content(PadX), header = HeaderHeight;
        // 머리줄 오른쪽 끝 ▲/▼ — 머리줄을 누르면 접고 편다
        var folded = Folded(snap);
        headerHits.Add((new Rectangle(0, top, Width, header), snap == claudeSnap ? "claude" : "codex"));
        int headRight = right - Content(Caret) - Content(6);
        DrawCaret(g, right - Content(Caret), top, header, folded);
        using (var brush = new SolidBrush(dot))
            g.FillEllipse(brush, left, top + (header - Content(DotSize)) / 2f, Content(DotSize), Content(DotSize));
        var x = left + Content(DotSize) + Content(6);
        var nameWidth = MeasureText(g, name, fontName!);
        DrawText(g, name, fontName!, new Rectangle(x, top, nameWidth, header), Palette.Text, TextFlags);

        if (folded)  // 「● Claude ▬▬── 26%」: 주간 한도만(없으면 첫 한도)
        {
            // 두 칸의 막대가 같은 자리에서 시작하게 이름 칸은 긴 쪽 너비로
            int barX = left + Content(DotSize) + Content(6) + Math.Max(MeasureText(g, "Claude", fontName!), MeasureText(g, "ChatGPT", fontName!)) + Content(10);
            var weekly = snap.Windows.FirstOrDefault(w => w.Name == null && w.Minutes == 10_080) ?? snap.Windows.FirstOrDefault(w => w.Name == null);
            if (weekly == null)
            {
                DrawText(g, snap.Message ?? T("값이 없습니다"), fontSmall!, new Rectangle(barX, top, Math.Max(0, headRight - barX), header),
                         Palette.Secondary, TextFlags | TextFormatFlags.EndEllipsis);
                return top + header;
            }
            var leftPercent = weekly.LeftPercent(now);
            var tint = Palette.Status(leftPercent);
            int percentWidth = MeasureText(g, "100%", fontPercent!);
            DrawText(g, $"{leftPercent}%", fontPercent!, new Rectangle(headRight - percentWidth, top, percentWidth, header), tint, TextFlags | TextFormatFlags.Right);
            int barWidth = Math.Max(Content(10), headRight - percentWidth - Content(8) - barX);
            float barY = top + (header - Content(BarH)) / 2f;
            using (var track = new SolidBrush(Palette.Track)) FillCapsule(g, track, barX, barY, barWidth, Content(BarH));
            using (var fill = new SolidBrush(tint)) FillCapsule(g, fill, barX, barY, Math.Max(Content(3), barWidth * leftPercent / 100f), Content(BarH));
            return top + header;
        }
        x += nameWidth + Content(6);

        var age = Fmt.AgeText(snap.ObservedAt, now);
        var ageWidth = MeasureText(g, age, fontSmall!);
        DrawText(g, age, fontSmall!, new Rectangle(headRight - ageWidth, top, ageWidth, header), Palette.Tertiary, TextFlags | TextFormatFlags.Right);
        if (!string.IsNullOrEmpty(detail))
            DrawText(g, detail, fontSmall!, new Rectangle(x, top, Math.Max(0, headRight - ageWidth - Content(6) - x), header),
                                  Palette.Secondary, TextFlags | TextFormatFlags.EndEllipsis);

        var y = top + header;
        var windows = snap.VisibleWindows(showModels).ToList();
        if (windows.Count == 0)
        {
            y += Content(Gap);
            var height = RowHeight * 2 + Content(Gap);
            DrawText(g, snap.Message ?? T("값이 없습니다"), fontRow!, new Rectangle(left, y, right - left, height),
                                  Palette.Secondary, TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix | TextFormatFlags.WordBreak
                                  | TextFormatFlags.EndEllipsis);
            return y + height;
        }
        foreach (var window in windows)
        {
            y += Content(Gap);
            DrawRow(g, window, left, right, y);
            y += RowHeight;
        }
        return y;
    }

    const int Caret = 8;

    /// 접힘 ▼ / 펼침 ▲
    void DrawCaret(Graphics g, int x, int top, int height, bool folded)
    {
        float w = Content(Caret), h = Content(Caret) * 0.55f, y = top + (height - h) / 2f;
        PointF[] points = folded
            ? [new(x, y), new(x + w, y), new(x + w / 2, y + h)]
            : [new(x, y + h), new(x + w, y + h), new(x + w / 2, y)];
        var old = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var brush = new SolidBrush(Palette.Tertiary)) g.FillPolygon(brush, points);
        g.SmoothingMode = old;
    }

    string? HeaderAt(Point client) => headerHits.FirstOrDefault(h => h.Row.Contains(client)).Pane;

    void ToggleFold(string pane)
    {
        switch (pane)
        {
            case "sessions": sessionsFolded = Settings.Save(Settings.FoldSessions, sessionsFolded ? 0 : 1, sessionsFolded ? 1 : 0) == 1; break;
            case "claude": claudeFolded = Settings.Save(Settings.FoldClaude, claudeFolded ? 0 : 1, claudeFolded ? 1 : 0) == 1; break;
            default: codexFolded = Settings.Save(Settings.FoldCodex, codexFolded ? 0 : 1, codexFolded ? 1 : 0) == 1; break;
        }
        UpdateSpin();
        FitSize();
        Redraw(gauge: false);
    }

    /// 「5시간 ▬▬▬── 41% 남음 ↺ 20:20」
    void DrawRow(Graphics g, LimitWindow window, int left, int right, int y)
    {
        var height = RowHeight;
        var leftPercent = window.LeftPercent(now);
        var tint = Palette.Status(leftPercent);
        DrawText(g, window.Label, fontRow!, new Rectangle(left, y, labelWidth, height), Palette.Secondary, TextFlags | TextFormatFlags.EndEllipsis);

        int resetX = right - resetWidth, percentX = resetX - Content(ColGap) - percentWidth;
        int barX = left + labelWidth + Content(ColGap), barWidth = Math.Max(Content(10), percentX - Content(ColGap) - barX);
        float barY = y + (height - Content(BarH)) / 2f;
        using (var track = new SolidBrush(Palette.Track)) FillCapsule(g, track, barX, barY, barWidth, Content(BarH));
        using (var fill = new SolidBrush(tint)) FillCapsule(g, fill, barX, barY, Math.Max(Content(3), barWidth * leftPercent / 100f), Content(BarH));

        DrawText(g, T("{0}% 남음", leftPercent), fontPercent!, new Rectangle(percentX, y, percentWidth, height), tint,
                              TextFlags | TextFormatFlags.Right);
        var reset = Fmt.ResetText(window.ResetsAt, now);
        if (reset.Length > 0 && reset != T("초기화됨")) reset = "↺ " + reset;
        DrawText(g, reset, fontSmall!, new Rectangle(resetX, y, resetWidth, height), Palette.Secondary,
                              TextFlags | TextFormatFlags.Right);
    }

    static void FillCapsule(Graphics g, Brush brush, float x, float y, float width, float height)
    {
        width = Math.Max(width, height);
        using var path = new GraphicsPath();
        path.AddArc(x, y, height, height, 90, 180);
        path.AddArc(x + width - height, y, height, height, 270, 180);
        path.CloseFigure();
        g.FillPath(brush, path);
    }

    // MARK: 작업 표시줄 간단 모드

    /// 1초마다: 표시 방식이 작업 표시줄이면 게이지를 붙이고(탐색기가 다시 켜지면 새로 붙인다) 떠 있는 창은 숨긴다.
    /// 붙일 수 없으면 떠 있는 창을 대신 보인다 — 탐색기 재시작처럼 잠깐인 경우를 위해 3초 기다린다
    void SyncTaskbar()
    {
        if (IsDisposed) return;
        string? problem = null;
        if (displayMode == 1)
        {
            var bar = TaskbarGauge.FindTaskbar();
            if (gauge != null && !gauge.Attached(bar)) DropGauge();
            if (bar == IntPtr.Zero) problem = T("작업 표시줄을 찾지 못했습니다");
            else
            {
                if (gauge == null)
                {
                    gauge = new TaskbarGauge(bar);
                    gauge.FloatRequested += () => BeginInvoke(new Action(() => ChooseAppearance(Settings.DisplayMode, 0)));  // 두 번 클릭: 떠 있는 창으로(게이지를 없애므로 그 클릭 처리가 끝난 뒤에)
                    gauge.MenuRequested += ShowMenuAt;
                    gauge.SessionsRequested += ToggleSessionPopup;
                    try
                    {
                        gauge.Show();
                        problem = PushGauge();
                    }
                    catch (Exception e) when (e is Win32Exception or InvalidOperationException)
                    {
                        problem = e.Message;
                        DropGauge();
                    }
                }
                if (gauge != null) problem ??= gauge.Tick();
            }
        }
        else DropGauge();

        taskbarFailures = problem == null ? 0 : taskbarFailures + 1;
        if (displayMode == 1 && (problem ?? "붙음") is var state && state != taskbarLogged) LogTaskbar(taskbarLogged = state);
        taskbarProblem = problem;
        bool floating = displayMode == 0 || (problem != null && (Visible || taskbarFailures >= 3));
        if (floating && !Visible)
        {
            Show();
            FitSize();
            Redraw();
        }
        else if (!floating && Visible) Hide();
    }

    /// 작업 표시줄에 붙었다·못 붙였다가 바뀔 때만 한 줄(~/.cache/ai-usage/taskbar.log, 64KB 넘으면 새로)
    static void LogTaskbar(string line)
    {
        try
        {
            var path = Path.Combine(Paths.Home, ".cache", "ai-usage", "taskbar.log");
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            if (File.Exists(path) && new FileInfo(path).Length > 65_536) File.Delete(path);
            File.AppendAllText(path, $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss} {line}{System.Environment.NewLine}");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    void DropGauge()
    {
        popup?.Close();
        gauge?.Dispose();
        gauge = null;
    }

    /// 지금 값을 게이지에 넘긴다. 그리지 못했으면 이유
    string? PushGauge() => gauge is { IsHandleCreated: true } g ? g.SetData(GaugeGroups(), taskbarSize, showSessions ? sessions.Count(s => s.State == SessionState.Waiting) : 0) : null;

    /// 「칸 순서」대로 회사마다 색 점 하나와 원들(5시간·주간·모델별)
    List<TaskbarGauge.Group> GaugeGroups() => Panes.Select(pane =>
    {
        var (name, snap, dot) = pane == Pane.Codex ? ("ChatGPT", codexSnap, Palette.ChatGPT) : ("Claude", claudeSnap, Palette.Claude);
        var rings = snap.VisibleWindows(showModels).Select(w => new TaskbarGauge.Ring(
            $"{name} · " + T("{0} {1}% 남음 · 초기화 {2}", w.Label, w.LeftPercent(now), w.ResetsAt is { } r ? Fmt.FullTime(r) : "-"),
            w.LeftPercent(now))).ToList();
        if (rings.Count == 0) rings.Add(new TaskbarGauge.Ring($"{name} · {snap.Message ?? T("값이 없습니다")}", null));
        return new TaskbarGauge.Group(dot, rings);
    }).ToList();

    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);

    /// 게이지를 오른쪽 클릭하면 떠 있는 창과 같은 메뉴
    void ShowMenuAt(Point at)
    {
        if (menuAnchor.Handle == IntPtr.Zero) menuAnchor.CreateHandle(new CreateParams());
        SetForegroundWindow(menuAnchor.Handle);  // 알림 영역 아이콘 메뉴처럼: 다른 곳을 누르면 메뉴가 닫히게
        menu.Show(at);
    }

    // MARK: 세션

    void ReadSessions()
    {
        if (IsDisposed) return;
        sessions = sessionReader.Read(DateTimeOffset.Now);
        if (popup is { Visible: true }) popup.SetSessions(sessions, DateTimeOffset.Now, spin);
        UpdateSpin();
        FitSize();
        Redraw();
    }

    /// 세션 칸(맨 위): 「세션」 머리 아래 한 줄씩
    int DrawSessions(Graphics g, int top)
    {
        int left = Content(PadX), right = Width - Content(PadX);
        headerHits.Add((new Rectangle(0, top, Width, HeaderHeight), "sessions"));
        DrawCaret(g, right - Content(Caret), top, HeaderHeight, sessionsFolded);
        DrawText(g, T("세션"), fontName!, new Rectangle(left, top, right - left, HeaderHeight), Palette.Text, TextFlags);
        if (sessionsFolded)  // 「세션 · 입력 1 · 진행 1 · 완료 2 ▼」 — 0개는 빼고, 입력 필요는 주황
        {
            int waiting = sessions.Count(s => s.State == SessionState.Waiting);
            int working = sessions.Count(s => s.State == SessionState.Working);
            int done = sessions.Count(s => s.State == SessionState.Done);
            var parts = new (int Count, string Text, Color Color)[]
            {
                (waiting, T("입력 {0}", waiting), Palette.Waiting),
                (working, T("진행 {0}", working), Palette.Working),
                (done, T("완료 {0}", done), Palette.Secondary),
            }.Where(p => p.Count > 0).ToList();
            int x = right - Content(Caret) - Content(6);
            for (int i = parts.Count - 1; i >= 0; i--)
            {
                int w = MeasureText(g, parts[i].Text, fontSmall!);
                DrawText(g, parts[i].Text, fontSmall!, new Rectangle(x - w, top, w, HeaderHeight), parts[i].Color, TextFlags | TextFormatFlags.Right);
                x -= w;
                if (i == 0) break;
                int dw = MeasureText(g, " · ", fontSmall!);
                DrawText(g, " · ", fontSmall!, new Rectangle(x - dw, top, dw, HeaderHeight), Palette.Tertiary, TextFlags | TextFormatFlags.Right);
                x -= dw;
            }
            return top + HeaderHeight;
        }
        var y = top + HeaderHeight;
        var (shown, hidden) = SessionRow.Visible(sessions);
        var at = DateTimeOffset.Now;
        foreach (var s in shown)
        {
            y += Content(Gap);
            sessionHits.Add((new Rectangle(left, y - Content(Gap) / 2, right - left, RowHeight + Content(Gap)), s));
            if (s.Id == hoverSession)
                SessionRow.Highlight(g, new Rectangle(left - Content(5), y - Content(Gap) / 2, right - left + Content(10), RowHeight + Content(Gap)), Content(5));
            SessionRow.Draw(g, s, new Rectangle(left, y, right - left, RowHeight), at, spin, fontRow!, fontSmall!,
                (text, font, rect, color, flags) => DrawText(g, text, font, rect, color, flags), (text, font) => MeasureText(g, text, font));
            y += RowHeight;
        }
        if (hidden > 0)
        {
            y += Content(Gap);
            DrawText(g, T("외 {0}개", hidden), fontSmall!, new Rectangle(left, y, right - left, RowHeight), Palette.Tertiary, TextFlags);
            y += RowHeight;
        }
        return y;
    }

    AgentSession? SessionAt(Point client) => sessionHits.FirstOrDefault(h => h.Row.Contains(client)).Session;
    string? hoverSession;  // 마우스가 올라간 세션 줄(밝은 바탕)

    void HoverSession(Point? at)
    {
        var id = at is { } p ? SessionAt(p)?.Id : null;
        Cursor = id != null || (at is { } q && HeaderAt(q) != null) ? Cursors.Hand : Cursors.Default;
        if (id == hoverSession) return;
        hoverSession = id;
        Redraw(gauge: false);
    }

    /// 작업 중인 세션이 보이는 동안만 고리를 돌린다
    bool Spinning => sessions.Any(s => s.State == SessionState.Working) && ((Visible && SessionRows > 0 && !sessionsFolded) || popup is { Visible: true });

    void UpdateSpin()
    {
        if (Spinning) spinTimer.Start();
        else spinTimer.Stop();
    }

    void Spin()
    {
        spin = (spin + 30) % 360;
        if (Visible && SessionRows > 0) Redraw(gauge: false);
        popup?.Spin(spin);
        if (!Spinning) spinTimer.Stop();
    }

    void ToggleSessionDisplay()
    {
        showSessions = Settings.Save(Settings.ShowSessions, showSessions ? 0 : 1, showSessions ? 1 : 0) == 1;
        UpdateSpin();
        FitSize();
        Redraw();
    }

    /// 간단 모드에서 게이지를 한 번 누르면 세션 패널을 열고, 열려 있으면 닫는다
    void ToggleSessionPopup(Rectangle gaugeBounds, int taskbarTop, int dpi)
    {
        popup ??= new SessionPopup();
        if (popup.Visible || popup.JustClosed)  // 열린 채로 게이지를 누르면 그 클릭에 먼저 닫힌다
        {
            popup.Close();
            return;
        }
        popup.ShowAbove(gaugeBounds, taskbarTop, dpi, sessions, DateTimeOffset.Now);
        UpdateSpin();
    }

    // MARK: 메뉴(창 오른쪽 클릭)

    // 메뉴: 위는 요약(세션 이름·상태, 회사마다 한도 한 줄), 아래는 묶음(보기·모양·알림·설정).
    // 긴 글은 「…」로 줄이고 전체는 풍선(ToolTip)으로 — 세션 이름·경로 때문에 메뉴가 넓어지지 않게

    const int MenuTextMax = 28;

    static string Shorten(string text, int max = MenuTextMax) => text.Length <= max ? text : text[..(max - 1)].TrimEnd() + "…";

    /// 누를 수 없는 회색 줄(긴 글은 줄이고 전체는 풍선)
    static ToolStripMenuItem Info(string text) => new(Shorten(text, 40)) { Enabled = false, ToolTipText = text.Length > 40 ? text : null };

    static readonly Dictionary<SessionTool, Bitmap> toolDots = new();

    /// 세션 줄 앞의 작은 점(주황 Claude, 초록 Codex)
    static Bitmap ToolDot(SessionTool tool)
    {
        if (toolDots.TryGetValue(tool, out var made)) return made;
        var bitmap = new Bitmap(16, 16);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using var brush = new SolidBrush(tool == SessionTool.Claude ? Palette.Claude : Palette.ChatGPT);
            g.FillEllipse(brush, 4, 4, 8, 8);
        }
        return toolDots[tool] = bitmap;
    }

    /// 하위 메뉴(오른쪽에 지금 값을 흐리게)
    static ToolStripMenuItem Group(string title, string? value = null)
    {
        // 하위 메뉴가 있는 항목은 WinForms 가 오른쪽 글(ShortcutKeyDisplayString)을 그리지 않아서, 값은 Tag 에 두고 MenuRenderer 가 그린다.
        var item = new ToolStripMenuItem(title) { Tag = value };
        if (item.DropDown is ToolStripDropDownMenu drop) drop.ShowItemToolTips = true;
        return item;
    }

    /// 메뉴 그리기: 하위 메뉴 항목 오른쪽(화살표 앞)에 지금 값(Tag)을 흐리게
    sealed class MenuRenderer : ToolStripProfessionalRenderer
    {
        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
        {
            base.OnRenderItemText(e);
            if (e.Item is not ToolStripMenuItem { HasDropDownItems: true, Tag: string value } item || e.Text != item.Text) return;
            var size = TextRenderer.MeasureText(e.Graphics, value, e.TextFont, Size.Empty, TextFormatFlags.NoPadding);
            // 항목의 Width 는 메뉴보다 넓게 잡힐 수 있어, 보이는 메뉴 폭에서 화살표 자리를 뺀 곳에 맞춘다
            int right = e.ToolStrip.Width - item.Bounds.X - (int)(item.Height * 1.5);
            var rect = new Rectangle(right - size.Width, e.TextRectangle.Top, size.Width, e.TextRectangle.Height);
            TextRenderer.DrawText(e.Graphics, value, e.TextFont, rect, SystemColors.GrayText,
                TextFormatFlags.NoPadding | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
        }
    }

    readonly MenuRenderer menuRenderer = new();

    /// 하위 메뉴까지 같은 그리기
    void UseRenderer(ToolStripItemCollection items)
    {
        foreach (var item in items.OfType<ToolStripMenuItem>().Where(i => i.HasDropDownItems))
        {
            item.DropDown.Renderer = menuRenderer;
            UseRenderer(item.DropDownItems);
        }
    }

    void OnMenuOpening(object? sender, CancelEventArgs e)
    {
        menu.Items.Clear();
        menu.ShowItemToolTips = true;
        var at = DateTimeOffset.Now;
        if (taskbarProblem != null) menu.Items.Add(Info(T("작업 표시줄 대신 떠 있는 창 — {0}", taskbarProblem)));

        // 세션: 이름(줄임)과 상태. 누르면 그 대화가 열리고, 풍선에 전체 이름·폴더
        if (showSessions && sessions.Count > 0)
        {
            menu.Items.Add(new ToolStripMenuItem(T("세션")) { Enabled = false });
            var (shown, hidden) = SessionRow.Visible(sessions);
            foreach (var s in shown)
                menu.Items.Add(new ToolStripMenuItem(Shorten(s.Name, 24), ToolDot(s.Tool), (_, _) => SessionOpener.Open(s))
                {
                    ShortcutKeyDisplayString = s.StatusText(at),
                    ToolTipText = s.Describe(at),
                });
            if (hidden > 0) menu.Items.Add(Info(T("외 {0}개", hidden)));
        }

        // 남은 한도: 회사마다 한 줄(모델별 줄은 빼고), 오른쪽에 확인 시각. 초기화 시각·출처·오류는 「자세히」
        menu.Items.Add(new ToolStripMenuItem(T("남은 한도")) { Enabled = false });
        ToolStripMenuItem Summary(string name, ProviderSnapshot snap)
        {
            var windows = snap.Windows.Where(w => w.Name == null).ToList();
            var text = windows.Count == 0 ? $"{name} · {snap.Message ?? T("값이 없습니다")}"
                : $"{name}  " + string.Join(" · ", windows.Select(w => $"{w.Label} {w.LeftPercent(now)}%"));
            return new ToolStripMenuItem(Shorten(text, 40))
            {
                Enabled = false,
                ShortcutKeyDisplayString = snap.ObservedAt is { } seen ? Fmt.Clock(seen) : null,
                ToolTipText = text.Length > 40 ? text : null,
            };
        }
        foreach (var pane in order)
        {
            if (pane == Pane.Claude && showClaude) menu.Items.Add(Summary("Claude", claudeSnap));
            if (pane == Pane.Codex && showCodex) menu.Items.Add(Summary("ChatGPT", codexSnap));
        }
        var details = Group(T("자세히"));
        foreach (var line in DetailLines()) details.DropDownItems.Add(new ToolStripMenuItem(line) { Enabled = false });
        menu.Items.Add(details);

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(T("지금 새로고침"), null, (_, _) => RefreshAll());
        menu.Items.Add(T("사용 추이…"), null, (_, _) => OpenTrend());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(ViewMenu());
        menu.Items.Add(AppearanceMenu());
        menu.Items.Add(AlertsMenu());
        menu.Items.Add(SettingsMenu());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(T("종료"), null, (_, _) => Close());
        menu.Renderer = menuRenderer;
        UseRenderer(menu.Items);
        e.Cancel = false;  // 항목을 여기서 채우므로 열리게 둔다
    }

    /// 보기: 어떤 칸을 보일지, 칸 순서, 모두 접기·펼치기
    ToolStripMenuItem ViewMenu()
    {
        var root = Group(T("보기"));
        // 혼자 켜져 있는 Claude·ChatGPT 는 끌 수 없다(흐리게) — 맥판과 같다
        root.DropDownItems.Add(new ToolStripMenuItem(T("세션"), null, (_, _) => ToggleSessionDisplay()) { Checked = showSessions });
        root.DropDownItems.Add(new ToolStripMenuItem("Claude", null, (_, _) => SetShown(!showClaude, showCodex)) { Checked = showClaude, Enabled = showCodex });
        root.DropDownItems.Add(new ToolStripMenuItem("ChatGPT", null, (_, _) => SetShown(showClaude, !showCodex)) { Checked = showCodex, Enabled = showClaude });
        root.DropDownItems.Add(new ToolStripMenuItem(T("모델별 한도 (Fable 등)"), null, (_, _) => ToggleModelDisplay()) { Checked = showModels });
        root.DropDownItems.Add(new ToolStripSeparator());
        root.DropDownItems.Add(OrderMenu());
        bool anyFolded = sessionsFolded || claudeFolded || codexFolded, allFolded = sessionsFolded && claudeFolded && codexFolded;
        root.DropDownItems.Add(new ToolStripMenuItem(T("모두 펼치기"), null, (_, _) => FoldAll(false)) { Enabled = anyFolded });
        root.DropDownItems.Add(new ToolStripMenuItem(T("모두 접기"), null, (_, _) => FoldAll(true)) { Enabled = !allFolded });
        return root;
    }

    /// 칸 순서: 지금 순서를 보여 주고, 누른 칸을 한 칸 위로(맨 위 칸은 흐리게)
    ToolStripMenuItem OrderMenu()
    {
        var root = Group(T("칸 순서"));
        root.DropDownItems.Add(new ToolStripMenuItem(T("지금: {0}", string.Join(" → ", order.Select(Settings.Title)))) { Enabled = false });
        for (int i = 0; i < order.Length; i++)
        {
            var pane = order[i];
            int index = i;
            root.DropDownItems.Add(new ToolStripMenuItem(T("{0} 위로", Settings.Title(pane)), null, (_, _) =>
            {
                var next = order.ToArray();
                (next[index - 1], next[index]) = (next[index], next[index - 1]);
                if (Settings.Orders.FirstOrDefault(o => o.SequenceEqual(next)) is { } choice) ChooseOrder(choice);
            }) { Enabled = index > 0 });
        }
        return root;
    }

    void FoldAll(bool fold)
    {
        int value = fold ? 1 : 0;
        sessionsFolded = Settings.Save(Settings.FoldSessions, value, sessionsFolded ? 1 : 0) == 1;
        claudeFolded = Settings.Save(Settings.FoldClaude, value, claudeFolded ? 1 : 0) == 1;
        codexFolded = Settings.Save(Settings.FoldCodex, value, codexFolded ? 1 : 0) == 1;
        UpdateSpin();
        FitSize();
        Redraw(gauge: false);
    }

    /// 모양: 표시 방식, 그리고 지금 모드에 맞는 것만(작업 표시줄이면 크기, 떠 있는 창이면 투명도·창 크기·글자 크기)
    ToolStripMenuItem AppearanceMenu()
    {
        var root = Group(T("모양"), displayMode == 1 ? T("작업 표시줄") : T("떠 있는 창"));
        void Radio(ToolStripItemCollection items, Settings.PetSetting setting, string[] labels, int current)
        {
            for (int i = 0; i < labels.Length; i++)
            {
                int value = setting.Values[i];
                items.Add(new ToolStripMenuItem(labels[i], null, (_, _) => ChooseAppearance(setting, value)) { Checked = value == current });
            }
        }
        void Choice(Settings.PetSetting setting, string title, string[] labels, int current)
        {
            int index = Array.IndexOf(setting.Values, current);
            var item = Group(title, index >= 0 ? labels[index] : null);
            Radio(item.DropDownItems, setting, labels, current);
            root.DropDownItems.Add(item);
        }
        root.DropDownItems.Add(new ToolStripMenuItem(T("표시 방식")) { Enabled = false });
        Radio(root.DropDownItems, Settings.DisplayMode, [T("떠 있는 창"), T("작업 표시줄 (간단 모드)")], displayMode);
        root.DropDownItems.Add(new ToolStripSeparator());
        string[] sizes = [T("작게"), T("보통"), T("크게"), T("아주 크게")];
        if (displayMode == 1)
        {
            root.DropDownItems.Add(new ToolStripMenuItem(T("작업 표시줄 크기")) { Enabled = false });
            Radio(root.DropDownItems, Settings.TaskbarSize, [T("작게"), T("크게")], taskbarSize);
        }
        else
        {
            Choice(Settings.Background, T("배경 투명도"), [T("없음"), T("조금"), T("중간"), T("많이")], backgroundLevel);
            Choice(Settings.WindowSize, T("창 크기"), sizes, windowPercent);
            Choice(Settings.TextSize, T("글자 크기"), sizes, textPercent);
        }
        return root;
    }

    /// 알림: 한도 알림, 모델별 한도도 알림
    ToolStripMenuItem AlertsMenu()
    {
        var root = Group(T("알림"), Settings.LimitAlerts ? T("켬") : T("끔"));
        root.DropDownItems.Add(new ToolStripMenuItem(T("한도 알림"), null, (_, _) => ToggleAlerts()) { Checked = Settings.LimitAlerts });
        root.DropDownItems.Add(new ToolStripMenuItem(T("모델별 한도도 알림"), null, (_, _) => ToggleModelAlerts())
            { Enabled = Settings.LimitAlerts, Checked = Settings.LimitAlerts && modelAlerts });
        return root;
    }

    /// 설정: 자동 실행, 상태 표시줄 연결, 언어, 위치 초기화, 설치·업데이트
    ToolStripMenuItem SettingsMenu()
    {
        var root = Group(T("설정"));
        root.DropDownItems.Add(new ToolStripMenuItem(T("Windows 시작할 때 자동으로 열기"), null, (_, _) => AutoStart.Set(!AutoStart.IsOn)) { Checked = AutoStart.IsOn });
        root.DropDownItems.Add(new ToolStripMenuItem(T("Claude Code 상태 표시줄 연결"), null, (_, _) => { ClaudeLink.Ask(fromMenu: true); RefreshLocal(); })
        {
            Checked = ClaudeSettings.State() == ClaudeSettings.LinkState.Connected,
        });
        root.DropDownItems.Add(LanguageMenu());
        root.DropDownItems.Add(new ToolStripSeparator());
        root.DropDownItems.Add(T("위치 초기화"), null, (_, _) => PlaceWindow(reset: true));
        if (!Installer.IsInstalled)
            root.DropDownItems.Add(T("설치(시작 메뉴에 등록)"), null, (_, _) => { if (Installer.InstallAndRelaunch(mutex)) Close(); });
        root.DropDownItems.Add(new ToolStripMenuItem(T("업데이트 확인 (지금 {0})", Updater.Current), null, (_, _) => CheckForUpdate(manual: true))
        {
            Enabled = !updating,
        });
        return root;
    }

    void ChooseAppearance(Settings.PetSetting setting, int value)
    {
        if (setting == Settings.DisplayMode)
        {
            if (value == displayMode) return;
            displayMode = Settings.Save(setting, value, displayMode);
            taskbarFailures = 0;
            SyncTaskbar();
            return;
        }
        if (setting == Settings.TaskbarSize)
        {
            if (value == taskbarSize) return;
            taskbarSize = Settings.Save(setting, value, taskbarSize);
            PushGauge();
            SyncTaskbar();  // 폭이 바뀌었으니 바로 자리를 다시 잡는다
            return;
        }
        if (setting == Settings.Background)
        {
            if ((layeredFailed && value != 0) || (value == backgroundLevel && value == savedBackground)) return;
            SetBackground(value);
            if (backgroundLevel != value) return; // Failed alpha check or submission.
            savedBackground = Settings.Save(setting, value, savedBackground);
            if (savedBackground != value && (!layeredFailed || savedBackground == 0)) SetBackground(savedBackground);
            return;
        }

        int previous = setting == Settings.WindowSize ? windowPercent : textPercent;
        if (value == previous) return;
        SetScale(setting, value);
        int stored = Settings.Save(setting, value, previous);
        if (stored != value) SetScale(setting, stored);
    }

    void SetBackground(int level)
    {
        backgroundLevel = level;
        UpdateStyles();
        ApplyCorners();
        Redraw();
    }

    void SetScale(Settings.PetSetting setting, int value)
    {
        if (setting == Settings.WindowSize) windowPercent = value;
        else textPercent = value;
        MakeFonts();
        FitSize();
        Redraw();
    }

    /// 「언어」 — 자동(Windows 표시 언어)과 언어 이름(각 언어로 적은 이름)
    ToolStripMenuItem LanguageMenu()
    {
        var item = new ToolStripMenuItem(T("언어 (Language)"));
        var choice = L10n.Choice;
        item.DropDownItems.Add(new ToolStripMenuItem(T("자동 (시스템 언어)"), null, (_, _) => ChooseLanguage("auto")) { Checked = choice == "auto" });
        item.DropDownItems.Add(new ToolStripSeparator());
        foreach (var code in L10n.Codes)
            item.DropDownItems.Add(new ToolStripMenuItem(L10n.NativeNames[code], null, (_, _) => ChooseLanguage(code)) { Checked = choice == code });
        return item;
    }

    void ChooseLanguage(string code)
    {
        if (code == L10n.Choice) return;
        try
        {
            L10n.Choose(code);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return;
        }
        Text = T("AI 사용량");
        MeasureColumns(force: true);
        RefreshAll();  // 값에 붙은 안내 글도 새 언어로 다시 만든다
    }

    void ChooseOrder(Pane[] choice)
    {
        order = choice;
        Settings.Order = choice;
        if (trend != null) SyncUsage();
        Redraw();
    }

    IEnumerable<string> DetailLines()
    {
        IEnumerable<string> Values(string title, ProviderSnapshot snap)
        {
            yield return T("{0} · 마지막 값 {1}", title, snap.ObservedAt is { } at ? Fmt.FullTime(at) : T("없음"));
            foreach (var w in snap.VisibleWindows(showModels))
                yield return "    " + T("{0} {1}% 남음 · 초기화 {2}", w.Label, w.LeftPercent(now), w.ResetsAt is { } r ? Fmt.FullTime(r) : "-");
        }
        foreach (var pane in order)  // 창과 같은 순서로, 켜 둔 칸만(맥판과 같다)
        {
            switch (pane)
            {
                case Pane.Claude when showClaude:
                    foreach (var line in Values($"Claude ({claudeSnap.Source ?? T("Claude Code 상태 표시줄")})", claudeSnap)) yield return line;
                    // Claude 값이 오래됐고 데스크톱 앱 기록도 멈췄으면 다시 받게 하는 법을 알린다
                    if ((claudeSnap.ObservedAt is not { } seen || now - seen >= ClaudeDesktopUsage.StaleAfter)
                        && ClaudeDesktopUsage.StaleHint(now) is { } hint)
                        yield return "    " + hint;
                    var usageError = ClaudeUsageCommand.DisabledReason() ?? ClaudeUsageCommand.LastError;
                    yield return T("Claude /usage 확인 {0}", ClaudeUsageCommand.LastCheckedAt is { } u ? Fmt.Clock(u) : T("전"))
                                 + (usageError != null ? " — " + usageError : "");
                    break;
                case Pane.Codex when showCodex:
                    foreach (var line in Values(T("ChatGPT (Codex 한도)"), codexSnap)) yield return line;
                    yield return T("Codex 서버 확인 {0}", codex.ServerCheckedAt is { } c ? Fmt.Clock(c) : T("전"))
                                 + (codex.ServerError is { } error ? " — " + error : "");
                    break;
            }
        }
    }
}

static class Palette
{
    public static readonly Color Background = Color.FromArgb(0x1E, 0x1E, 0x20);
    public static readonly Color Text = Color.FromArgb(0xF2, 0xF2, 0xF4);
    public static readonly Color Secondary = Color.FromArgb(0xA1, 0xA1, 0xA6);
    public static readonly Color Tertiary = Color.FromArgb(0x6E, 0x6E, 0x73);
    public static readonly Color Track = Color.FromArgb(0x3A, 0x3A, 0x3D);
    public static readonly Color Divider = Color.FromArgb(0x2E, 0x2E, 0x31);
    public static readonly Color Claude = Color.FromArgb(0xD9, 0x77, 0x57);
    public static readonly Color ChatGPT = Color.FromArgb(0x10, 0xA3, 0x7F);
    // 세션 상태: 입력 필요 주황, 작업 중 파랑, 작업 완료 초록
    public static readonly Color Waiting = Color.FromArgb(0xFF, 0x9F, 0x0A);
    public static readonly Color Working = Color.FromArgb(0x0A, 0x84, 0xFF);
    public static readonly Color Done = Color.FromArgb(0x30, 0xD1, 0x58);

    /// 맥판과 같은 기준: 50% 이상 초록, 20% 이상 노랑, 그 아래 빨강
    public static Color Status(int left) => left >= 50 ? Color.FromArgb(0x30, 0xD1, 0x58)
        : left >= 20 ? Color.FromArgb(0xFF, 0xD6, 0x0A) : Color.FromArgb(0xFF, 0x45, 0x3A);
}

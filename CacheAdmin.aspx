<%@ Page Language="C#" AutoEventWireup="true" Debug="false" %>

<%@ Import Namespace="Sitecore.Caching" %>
<%@ Import Namespace="Sitecore.Configuration" %>
<%@ Import Namespace="System.Linq" %>
<%@ Import Namespace="System.Web" %>

<script runat="server">
    // =====================================================================
    //  SECURITY GATE — runs before anything else on every request.
    //  Only requests originating from the machine itself are served.
    //  Every other remote IP gets a plain 404, as if the file did not exist.
    //
    //  IMPORTANT: the decision is based ONLY on the real TCP peer address
    //  (REMOTE_ADDR / LOCAL_ADDR, set by IIS from the connection itself).
    //  We deliberately DO NOT look at X-Forwarded-For, X-Real-IP, Host or
    //  any other request header, because those are attacker-controllable
    //  and could be used to fake a "local" request.
    // =====================================================================
    protected void Page_PreInit(object sender, EventArgs e)
    {
        if (!IsLocalRequest())
        {
            Send404AndStop();
        }
    }

    private bool IsLocalRequest()
    {
        HttpRequest req = Request;

        // REMOTE_ADDR = the actual remote peer of the TCP connection.
        string remoteAddr = req.ServerVariables["REMOTE_ADDR"];
        if (string.IsNullOrEmpty(remoteAddr))
        {
            return false;
        }

        System.Net.IPAddress remoteIp;
        if (!System.Net.IPAddress.TryParse(remoteAddr, out remoteIp))
        {
            return false;
        }

        // 1) Loopback: 127.0.0.0/8 (IPv4) and ::1 (IPv6). This is the normal
        //    case when browsing http(s)://localhost from an RDP/Bastion session.
        if (System.Net.IPAddress.IsLoopback(remoteIp))
        {
            return true;
        }

        // 2) Request that originated from this same server, addressed to one of
        //    the machine's own IPs (e.g. browsing the machine's hostname / private
        //    IP locally). REMOTE_ADDR then equals LOCAL_ADDR.
        string localAddr = req.ServerVariables["LOCAL_ADDR"];
        if (!string.IsNullOrEmpty(localAddr) &&
            string.Equals(localAddr, remoteAddr, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return false;
    }

    private void Send404AndStop()
    {
        Response.Clear();
        // Skip IIS/ASP.NET custom error pages so the response is a clean 404
        // and does not reveal that this handler exists.
        Response.TrySkipIisCustomErrors = true;
        Response.StatusCode = 404;
        Response.StatusDescription = "Not Found";
        Response.ContentType = "text/html";
        Response.Write("<html><head><title>404 - Not Found</title></head>" +
                       "<body><h2>404 - File or directory not found.</h2>" +
                       "<p>The resource you are looking for might have been removed, " +
                       "had its name changed, or is temporarily unavailable.</p></body></html>");
        Response.End();
    }
</script>

<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <title>Cache Admin</title>
    <meta content="C#" name="CODE_LANGUAGE">
    <!-- No external dependencies: all client code below is vanilla JS, so this single .aspx
         is fully self-contained (works even on a VM with no outbound internet). -->

    <style type="text/css">
        body {
            font-family: 'Open Sans', sans-serif;
        }

        div {
            padding: 20px;
        }

        table {
            border-collapse: collapse;
        }

        table, th, td {
            border: 1px solid black;
            padding: 5px;
        }

        th {
            background-color: #F5F5F5;
        }

        td.AlignRight {
            text-align: right;
        }

        td.AlignCenter {
            text-align: center;
        }

        td.MaxSize {
            color: lightgray;
        }

        td.CacheUtilizationHigh {
        }

        td.CacheUtilizationLow {
            color: lightgray;
        }

        .status {
            background-color: #e8f5e9;
            border: 1px solid #66bb6a;
            padding: 10px 15px;
            margin: 0;
            display: inline-block;
        }

        .status.error {
            background-color: #ffebee;
            border-color: #ef5350;
        }

        button {
            cursor: pointer;
        }

        button.clear-all {
            background-color: #fff3e0;
            border: 1px solid #ffb74d;
            padding: 5px 10px;
        }

        /* ---- Live tracking controls + event log ---- */
        .tracking-controls {
            padding: 12px 20px;
            background-color: #eef3f8;
            border: 1px solid #cfd8dc;
            display: inline-block;
        }

        #btn-track {
            padding: 5px 12px;
        }

        #btn-track.tracking-on {
            background-color: #c8e6c9;
            border: 1px solid #66bb6a;
        }

        .track-status {
            margin-left: 20px;
            font-style: italic;
            color: #555;
        }

        .event-log-wrap {
            padding: 10px 20px 20px 20px;
        }

        .event-log-head {
            margin-bottom: 6px;
        }

        .event-log {
            max-height: 280px;
            overflow: auto;
            border: 1px solid #ccc;
            padding: 4px;
            background-color: #fafafa;
            font-family: Consolas, 'Courier New', monospace;
            font-size: 12px;
        }

        .event-log .ev {
            padding: 2px 5px;
            border-bottom: 1px solid #eee;
            white-space: nowrap;
            cursor: pointer;
        }

        .event-log .ev:hover {
            background-color: #eef;
        }

        /* Event-type colours, shared by the log and the per-row "Last Event" cell */
        .ev-ManualClear   { color: #1565c0; }
        .ev-ExternalClear { color: #6a1b9a; }
        .ev-AutoScavenged { color: #c62828; font-weight: bold; }

        /* Trend arrows in the per-row Trend cell */
        td.trend-up   { color: #2e7d32; font-weight: bold; }
        td.trend-down { color: #c62828; font-weight: bold; }

        /* Short-lived row flashes on change (class removed by JS after ~1.5s) */
        tr.flash-up td    { background-color: #c8e6c9 !important; transition: background-color 1.4s ease; }
        tr.flash-shrink td { background-color: #ffe0b2 !important; transition: background-color 1.4s ease; }
        tr.flash-clear td { background-color: #ef9a9a !important; transition: background-color 1.4s ease; }

        /* ---- Group / Kind filtering + summary ---- */
        .filter-controls {
            padding: 10px 20px;
            background-color: #f7f9fb;
            border: 1px solid #cfd8dc;
        }

        .filter-row {
            padding: 4px 0;
            line-height: 1.9;
        }

        .filter-label {
            display: inline-block;
            min-width: 60px;
            font-weight: bold;
            color: #444;
        }

        label.cb {
            display: inline-block;
            margin-right: 12px;
            padding: 1px 4px;
            white-space: nowrap;
            cursor: pointer;
        }

        .filter-presets { margin-left: 10px; }
        .filter-presets .preset { margin-right: 6px; }

        .filter-count {
            margin-left: 12px;
            font-style: italic;
            color: #666;
        }

        /* Group colour accents, shared by the Group cell, group checkboxes, and summary */
        .group-content { color: #1b5e20; }
        .group-system  { color: #8d6e00; }
        .group-db      { color: #0d47a1; }
        .group-named   { color: #4a148c; }

        td.group-cell { font-size: 12px; }
        td.kind-cell  { font-size: 12px; color: #555; }

        #summary-table {
            font-size: 13px;
        }

        #summary-table td, #summary-table th {
            padding: 3px 8px;
        }

        .summary-head {
            padding: 0 0 8px 0;
        }
    </style>

    <!-- Name filtering is handled by the unified applyFilters() in the script at the end of
         <body>, together with the Group/Kind/state filters. -->

    <script runat="server">
        public class CellEntry
        {
            public string Value { get; set; }
            public string CssClass { get; set; }
            public string Link { get; set; }
            public string RawHtml { get; set; }

            public static implicit operator CellEntry(string param)
            {
                return new CellEntry(param);
            }

            public CellEntry(string value, string cssClass = "", string link = "")
            {
                Value = value;
                CssClass = cssClass;
                Link = link;
            }
        }

        // ===================== Live tracking state =====================
        // These statics persist for the life of the IIS app pool: across requests,
        // across browser tabs, and across page reloads. That is deliberate — an
        // intermittent auto-scavenge is exactly what we don't want to lose by
        // refreshing. State only resets on an app-pool recycle (which we never
        // trigger) or via the "Reset stats" button. IIS serves requests
        // concurrently, so every read/write of these goes through TrackingLock.
        private static readonly object TrackingLock = new object();
        private static readonly Dictionary<string, CacheTrackState> TrackStates =
            new Dictionary<string, CacheTrackState>(StringComparer.Ordinal);
        private static readonly LinkedList<CacheEvent> EventLog = new LinkedList<CacheEvent>(); // newest at head
        private static int NextEventId = 1;
        private const int EventLogCap = 2000;

        // Per-cache running state used to diff one poll against the previous one.
        public class CacheTrackState
        {
            public long LastSize;
            public int LastCount;
            public long PeakSize;
            public long PeakUtilization;   // percent; -1 when not applicable (unlimited / zero max)
            public string LastEventType;   // null until the cache has a notable event
            public DateTime LastEventTime;
            public int EventCount;         // notable events only (scavenge / clears), not minor shrinks
        }

        // A single notable change worth logging. Minor shrinks (TTL/expiry) are NOT recorded here.
        public class CacheEvent
        {
            public int Id;
            public DateTime Timestamp;
            public string CacheName;
            public string Type;            // ManualClear | ExternalClear | AutoScavenged
            public long SizeBefore;
            public long SizeAfter;
            public int CountBefore;
            public int CountAfter;
            public long MaxSize;
            public long UtilizationBeforeDrop; // percent; -1 when not applicable
        }

        // ===================== Cache taxonomy (Group / Kind) =====================
        // Every cache name is either "{owner}[{kind}]" or a standalone named cache. The [kind]
        // suffix tells us what the cache does; the two suffix sets below are disjoint, so the
        // suffix alone reliably separates database caches from per-site caches — no fragile
        // owner-name matching. Group ordering constants also drive the checkbox / summary layout.
        private static readonly string[] SiteKindOrder =
            { "html", "filtered items", "filtered items preview", "renderingParameters", "xsl", "viewstate", "registry" };
        private static readonly string[] DbKindOrder =
            { "items", "data", "paths", "itempaths", "blobIDs", "standardValues",
              "languageFallback", "languageFallbackObsolete", "isLanguageFallbackValid", "isLanguageFallbackValidObsolete" };

        private static readonly HashSet<string> SiteKinds =
            new HashSet<string>(SiteKindOrder, StringComparer.OrdinalIgnoreCase);
        private static readonly HashSet<string> DbKinds =
            new HashSet<string>(DbKindOrder, StringComparer.OrdinalIgnoreCase);

        // Built-in Sitecore sites (vs. the customer's content sites). Used only to label the
        // Group column; an unknown owner is treated as a content site.
        private static readonly HashSet<string> SystemSites = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            { "shell", "login", "admin", "service", "modules_shell", "modules_website",
              "scheduler", "system", "publisher", "testing", "form" };

        // Kinds hidden on first load (user's "never used"). Client localStorage overrides after that.
        private static readonly HashSet<string> DefaultHiddenKinds =
            new HashSet<string>(new[] { "xsl", "viewstate", "registry", "languageFallbackObsolete", "isLanguageFallbackValidObsolete" }, 
                StringComparer.OrdinalIgnoreCase);

        public const string GroupContentSite = "Content site";
        public const string GroupSystemSite = "System site";
        public const string GroupDatabase = "Database";
        public const string GroupNamed = "Named";
        public const string KindNamed = "named"; // synthetic kind for standalone caches

        // Splits a cache name into (Group, Kind). Kind is the [suffix] for structured names, or
        // the synthetic "named" for standalone caches.
        private void ClassifyCache(string name, out string group, out string kind)
        {
            int open = name.LastIndexOf('[');
            int close = name.LastIndexOf(']');
            if (open > 0 && close == name.Length - 1 && close > open + 1)
            {
                string owner = name.Substring(0, open);
                string suffix = name.Substring(open + 1, close - open - 1);

                if (DbKinds.Contains(suffix)) { group = GroupDatabase; kind = suffix; return; }
                if (SiteKinds.Contains(suffix))
                {
                    group = SystemSites.Contains(owner) ? GroupSystemSite : GroupContentSite;
                    kind = suffix;
                    return;
                }
            }

            // No recognizable owner[kind] structure (e.g. AccessResultCache, mvc[rendererCacheKeys],
            // IsDisplayedInSearchResults[master], "[FieldReaderCache, Id: ...]") → a named cache.
            group = GroupNamed;
            kind = KindNamed;
        }

        // Stable display order for groups (used to sort the summary and the group sort option).
        private int GroupOrder(string group)
        {
            switch (group)
            {
                case GroupContentSite: return 0;
                case GroupSystemSite: return 1;
                case GroupDatabase: return 2;
                default: return 3; // Named
            }
        }

        // A CSS-safe suffix for a group (for colour-coding the Group cell / checkboxes).
        private string GroupCssSuffix(string group)
        {
            switch (group)
            {
                case GroupContentSite: return "content";
                case GroupSystemSite: return "system";
                case GroupDatabase: return "db";
                default: return "named";
            }
        }

        // Aggregate stats for one Kind, shown in the summary panel.
        public class KindSummary
        {
            public string Kind;
            public string Group;
            public int Caches;
            public int NonEmpty;
            public long TotalSize;
            public int Events;      // sum of notable events across caches of this kind
            public int Scavenged;   // caches whose last event was an auto-scavenge
        }

        // Rolls every cache up by Kind. Used for both the server-rendered summary table and the
        // live JSON summary. `states` is the tracking dict (locked snapshot or the live TrackStates).
        private List<KindSummary> BuildKindSummary(ICacheInfo[] allCaches, Dictionary<string, CacheTrackState> states)
        {
            Dictionary<string, KindSummary> map = new Dictionary<string, KindSummary>(StringComparer.Ordinal);

            foreach (ICacheInfo cache in allCaches)
            {
                string group, kind;
                ClassifyCache(cache.Name, out group, out kind);

                KindSummary s;
                if (!map.TryGetValue(kind, out s))
                {
                    s = new KindSummary { Kind = kind, Group = group };
                    map[kind] = s;
                }
                // A kind can appear under more than one group (site kinds on both content & system
                // sites); label it with the group of its first-seen owner — good enough for the panel.
                s.Caches++;
                if (cache.Count > 0) s.NonEmpty++;
                s.TotalSize += cache.Size;

                CacheTrackState st;
                if (states != null && states.TryGetValue(cache.Name, out st))
                {
                    s.Events += st.EventCount;
                    if (st.LastEventType == "AutoScavenged") s.Scavenged++;
                }
            }

            List<KindSummary> list = new List<KindSummary>(map.Values);
            // Site kinds first (in preferred order), then DB kinds, then named; unknown kinds last.
            list.Sort((a, b) => KindRank(a.Kind).CompareTo(KindRank(b.Kind)));
            return list;
        }

        // Sort key: site kinds (0..), db kinds (100..), named (900), unknown (950).
        private int KindRank(string kind)
        {
            for (int i = 0; i < SiteKindOrder.Length; i++)
                if (string.Equals(SiteKindOrder[i], kind, StringComparison.OrdinalIgnoreCase)) return i;
            for (int i = 0; i < DbKindOrder.Length; i++)
                if (string.Equals(DbKindOrder[i], kind, StringComparison.OrdinalIgnoreCase)) return 100 + i;
            if (kind == KindNamed) return 900;
            return 950;
        }

        protected void Page_Load(object sender, EventArgs e)
        {
            // Force UTF-8 on the response so the arrows / accented cache names aren't mangled
            // when IIS's default charset is unset or non-UTF-8. Belt-and-suspenders alongside
            // the <meta charset> tag and the ASCII-safe glyph escapes in the client script.
            Response.ContentEncoding = System.Text.Encoding.UTF8;
            Response.Charset = "utf-8";

            // ---- Live-tracking poll endpoint. Return compact JSON and stop before
            //      building any HTML. Runs AFTER the Page_PreInit localhost gate, so
            //      it inherits the same "localhost only, else 404" protection. ----
            if (Request.QueryString["ajax"] == "snapshot")
            {
                WriteSnapshotJson();
                return; // WriteSnapshotJson ends the response; return is a safety net.
            }

            string statusMessage = null;
            bool statusIsError = false;

            // Handle clear / reset actions (POST only, so a plain GET / prefetch never mutates anything).
            if (string.Equals(Request.HttpMethod, "POST", StringComparison.OrdinalIgnoreCase))
            {
                if (!string.IsNullOrEmpty(Request.Form["reset"]))
                {
                    lock (TrackingLock)
                    {
                        TrackStates.Clear();
                        EventLog.Clear();
                        NextEventId = 1;
                    }
                    statusMessage = "Tracking statistics and event log reset.";
                }
                else if (!string.IsNullOrEmpty(Request.Form["clearall"]))
                {
                    statusMessage = ClearAllCaches();
                }
                else
                {
                    string clearName = Request.Form["clear"];
                    if (!string.IsNullOrEmpty(clearName))
                    {
                        statusMessage = ClearCache(clearName, out statusIsError);
                    }
                }
            }

            // Render Header
            string pageVersion = "4.0.1 (localhost-only admin, clear + live tracking + group/kind filtering)";
            string pageName = "Sitecore Cache Admin";
            Header.InnerHtml = string.Format("<h2>{0}</h2><h6>Version:&nbsp;{1}</h6>", pageName, pageVersion);

            // Render status message (if any)
            if (statusMessage != null)
            {
                Status.InnerHtml = string.Format("<div class='status{0}'>{1}</div>",
                    statusIsError ? " error" : "", statusMessage);
            }

            // Sort reads from either the query string (sort links) or the form (posted hidden field).
            string sort = Request["sort"];

            // Take one consistent snapshot of tracking state for this render. Used both for
            // sorting (events / peak utilization) and for the new per-row tracking columns.
            Dictionary<string, CacheTrackState> trackSnapshot;
            lock (TrackingLock)
            {
                trackSnapshot = new Dictionary<string, CacheTrackState>(TrackStates, StringComparer.Ordinal);
            }

            ICacheInfo[] allCaches = CacheManager.GetAllCaches();
            if (sort == "count")
            {
                allCaches = allCaches.OrderByDescending(c => c.Count).ToArray();
            }
            else if (sort == "size")
            {
                allCaches = allCaches.OrderByDescending(c => c.Size).ToArray();
            }
            else if (sort == "maxsize")
            {
                allCaches = allCaches.OrderByDescending(c => c.MaxSize).ToArray();
            }
            else if (sort == "utilization")
            {
                allCaches = allCaches.OrderByDescending(c => GetUtilization(c.Size, c.MaxSize)).ToArray();
            }
            else if (sort == "events")
            {
                allCaches = allCaches.OrderByDescending(c => GetTrackInt(trackSnapshot, c.Name, "events")).ToArray();
            }
            else if (sort == "peakutil")
            {
                allCaches = allCaches.OrderByDescending(c => GetTrackInt(trackSnapshot, c.Name, "peakutil")).ToArray();
            }
            else if (sort == "group")
            {
                allCaches = allCaches.OrderBy(c => GroupSortKey(c.Name)).ThenBy(c => c.Name).ToArray();
            }
            else if (sort == "kind")
            {
                allCaches = allCaches.OrderBy(c => KindSortKey(c.Name)).ThenBy(c => c.Name).ToArray();
            }
            else
            {
                allCaches = allCaches.OrderBy(c => c.Name).ToArray();
            }

            // Render Statistics
            CacheStatistics statistics = CacheManager.GetStatistics();
            Totals.InnerHtml = RenderOverviewTable(statistics, allCaches);

            // Render tracking controls + event log panel
            Tracking.InnerHtml = RenderTrackingControls();

            // Per-Kind summary (also drives the filter checkbox counts).
            List<KindSummary> summary = BuildKindSummary(allCaches, trackSnapshot);
            Summary.InnerHtml = RenderSummaryTable(summary);

            // Render Cache Sizes: name filter + group/kind/state filter controls + the table.
            Caches.InnerHtml = RenderFilterComponent(sort);
            Caches.InnerHtml += RenderFilterControls(allCaches);
            Caches.InnerHtml += RenderCacheSizeTable(allCaches, trackSnapshot);
        }

        // Helper for the two tracking-based sorts; returns a sortable long from the snapshot.
        private long GetTrackInt(Dictionary<string, CacheTrackState> snapshot, string name, string which)
        {
            CacheTrackState s;
            if (!snapshot.TryGetValue(name, out s))
            {
                return which == "peakutil" ? -1L : 0L;
            }
            return which == "peakutil" ? s.PeakUtilization : s.EventCount;
        }

        // Sort keys for the Group / Kind column sorts.
        private int GroupSortKey(string name)
        {
            string group, kind;
            ClassifyCache(name, out group, out kind);
            return GroupOrder(group);
        }

        private int KindSortKey(string name)
        {
            string group, kind;
            ClassifyCache(name, out group, out kind);
            return KindRank(kind);
        }

        private string ClearCache(string name, out bool isError)
        {
            isError = false;

            ICacheInfo cache = CacheManager.GetAllCaches().FirstOrDefault(c => c.Name == name);
            if (cache == null)
            {
                isError = true;
                return "Cache not found: " + Server.HtmlEncode(name);
            }

            string separator = "&nbsp";
            int countBefore = cache.Count;
            long sizeBefore = cache.Size;
            long maxSize = cache.MaxSize;
            long utilBefore = GetUtilization(sizeBefore, maxSize);

            cache.Clear();

            // Record as a ManualClear *now*, and reset this cache's baseline to the post-clear
            // values, so the next poll doesn't misread our own action as AutoScavenged/ExternalClear.
            lock (TrackingLock)
            {
                CacheTrackState state;
                if (!TrackStates.TryGetValue(name, out state))
                {
                    state = new CacheTrackState { PeakSize = sizeBefore, PeakUtilization = utilBefore };
                    TrackStates[name] = state;
                }
                RecordEvent(state, name, "ManualClear", sizeBefore, cache.Size, countBefore, cache.Count, maxSize, utilBefore);
                state.LastSize = cache.Size;
                state.LastCount = cache.Count;
            }

            return string.Format("Cleared cache '{0}' &mdash; removed {1} entries, freed {2}.",
                Server.HtmlEncode(name), countBefore, FormatSize(sizeBefore, separator));
        }

        private string ClearAllCaches()
        {
            int cleared = 0;

            lock (TrackingLock)
            {
                foreach (ICacheInfo cache in CacheManager.GetAllCaches())
                {
                    string name = cache.Name;
                    cache.Clear();
                    cleared++;

                    // Reset each baseline silently — otherwise the next poll would flag ~1250
                    // phantom drops. We log a single summary event below instead.
                    CacheTrackState state;
                    if (!TrackStates.TryGetValue(name, out state))
                    {
                        state = new CacheTrackState();
                        TrackStates[name] = state;
                    }
                    state.LastSize = cache.Size;
                    state.LastCount = cache.Count;
                }

                CacheEvent ev = new CacheEvent
                {
                    Id = NextEventId++,
                    Timestamp = DateTime.Now,
                    CacheName = "(all caches)",
                    Type = "ManualClear",
                    SizeBefore = 0,
                    SizeAfter = 0,
                    CountBefore = cleared, // number of caches cleared, shown specially in the log
                    CountAfter = 0,
                    MaxSize = 0,
                    UtilizationBeforeDrop = -1
                };
                EventLog.AddFirst(ev);
                while (EventLog.Count > EventLogCap)
                {
                    EventLog.RemoveLast();
                }
            }

            return string.Format("Cleared ALL {0} caches.", cleared);
        }

        private string RenderFilterComponent(string currentSort)
        {
            string separator = "&nbsp";

            string html = "<div style='padding: 20px 20px 20px 0px'>Filter by cache name:" + separator +
                          "<input type='text' id='input-filter'>";

            // Clear-all button lives inside the same form as the per-row Clear buttons.
            html += "<span style='margin-left:30px'><button type='submit' name='clearall' value='1' class='clear-all' " +
                    "onclick=\"return confirm('Clear ALL Sitecore caches on this server? Caches will rebuild on demand and may briefly impact performance.');\">" +
                    "Clear ALL caches</button></span>";

            // Preserve the current sort across the POST.
            html += string.Format("<input type='hidden' name='sort' value='{0}' />",
                HttpUtility.HtmlAttributeEncode(currentSort ?? string.Empty));

            html += "</div>";

            return html;
        }

        // Group / Kind / state filter checkboxes + preset buttons. All client-side (no name attrs,
        // so nothing here is posted). Counts are computed in one pass over the caches.
        private string RenderFilterControls(ICacheInfo[] allCaches)
        {
            Dictionary<string, int> groupCounts = new Dictionary<string, int>(StringComparer.Ordinal);
            Dictionary<string, int> kindCounts = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (ICacheInfo c in allCaches)
            {
                string g, k;
                ClassifyCache(c.Name, out g, out k);
                groupCounts[g] = groupCounts.ContainsKey(g) ? groupCounts[g] + 1 : 1;
                kindCounts[k] = kindCounts.ContainsKey(k) ? kindCounts[k] + 1 : 1;
            }

            StringBuilder sb = new StringBuilder();
            sb.Append("<div id='filter-controls' class='filter-controls'>");

            // ----- Groups -----
            sb.Append("<div class='filter-row'><span class='filter-label'>Groups:</span>");
            foreach (string g in new[] { GroupContentSite, GroupSystemSite, GroupDatabase, GroupNamed })
            {
                if (!groupCounts.ContainsKey(g)) continue;
                sb.Append(string.Format(
                    "<label class='cb group-{0}'><input type='checkbox' class='grp-cb' data-group=\"{1}\" checked> {2} ({3})</label>",
                    GroupCssSuffix(g), HttpUtility.HtmlAttributeEncode(g), HttpUtility.HtmlEncode(g), groupCounts[g]));
            }
            sb.Append("</div>");

            // ----- Kinds (site kinds, then db kinds, then named/unknown) -----
            sb.Append("<div class='filter-row'><span class='filter-label'>Kinds:</span>");
            List<string> ordered = new List<string>();
            foreach (string k in SiteKindOrder) if (kindCounts.ContainsKey(k)) ordered.Add(k);
            foreach (string k in DbKindOrder) if (kindCounts.ContainsKey(k)) ordered.Add(k);
            if (kindCounts.ContainsKey(KindNamed)) ordered.Add(KindNamed);
            foreach (string k in kindCounts.Keys)             // any unrecognised kinds last
                if (!ordered.Contains(k)) ordered.Add(k);

            foreach (string k in ordered)
            {
                bool hidden = DefaultHiddenKinds.Contains(k);
                string label = k == KindNamed ? "named" : k;
                sb.Append(string.Format(
                    "<label class='cb'><input type='checkbox' class='kind-cb' data-kind=\"{0}\"{1}> {2} ({3})</label>",
                    HttpUtility.HtmlAttributeEncode(k), hidden ? "" : " checked",
                    HttpUtility.HtmlEncode(label), kindCounts[k]));
            }
            sb.Append("</div>");

            // ----- State filters + presets -----
            sb.Append("<div class='filter-row'><span class='filter-label'>Show:</span>");
            sb.Append("<label class='cb'><input type='checkbox' id='cb-hide-empty'> Hide empty (count 0)</label>");
            sb.Append("<label class='cb'><input type='checkbox' id='cb-only-events'> Only caches with events</label>");
            sb.Append("<span class='filter-presets'>");
            sb.Append("<button type='button' class='preset' data-preset='never-used'>Hide never-used</button>");
            sb.Append("<button type='button' class='preset' data-preset='content'>Content sites only</button>");
            sb.Append("<button type='button' class='preset' data-preset='db'>Databases only</button>");
            sb.Append("<button type='button' class='preset' data-preset='named'>Named only</button>");
            sb.Append("<button type='button' class='preset' data-preset='all'>Show everything</button>");
            sb.Append("</span>");
            sb.Append("<span id='filter-visible-count' class='filter-count'></span>");
            sb.Append("</div>");

            sb.Append("</div>");
            return sb.ToString();
        }

        // Server-rendered summary panel. The client rebuilds #summary-tbody from the JSON summary
        // on each poll; RenderSummaryRows below is the shared row shape.
        private string RenderSummaryTable(List<KindSummary> summary)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("<div class='summary-head'>Summary by kind &mdash; totals across every cache of each kind. ");
            sb.Append("Spot which <i>kinds</i> are large or churning without scrolling the full list; ");
            sb.Append("<b class='ev-AutoScavenged'>Scavenged</b> = caches whose last event was an auto-scavenge.</div>");
            sb.Append("<table id='summary-table'><thead><tr>");
            sb.Append("<th>Kind</th><th>Group</th><th>Caches</th><th>Non-empty</th><th>Total size</th><th>Events</th><th>Scavenged</th>");
            sb.Append("</tr></thead><tbody id='summary-tbody'>");
            sb.Append(RenderSummaryRows(summary));
            sb.Append("</tbody></table>");
            return sb.ToString();
        }

        private string RenderSummaryRows(List<KindSummary> summary)
        {
            StringBuilder sb = new StringBuilder();
            foreach (KindSummary ks in summary)
            {
                string kindLabel = ks.Kind == KindNamed ? "named" : ks.Kind;
                sb.Append("<tr>");
                sb.Append("<td>").Append(HttpUtility.HtmlEncode(kindLabel)).Append("</td>");
                sb.Append("<td class='group-").Append(GroupCssSuffix(ks.Group)).Append("'>")
                  .Append(HttpUtility.HtmlEncode(ks.Group)).Append("</td>");
                sb.Append("<td class='AlignRight'>").Append(ks.Caches).Append("</td>");
                sb.Append("<td class='AlignRight'>").Append(ks.NonEmpty).Append("</td>");
                sb.Append("<td class='AlignRight'>").Append(FormatSize(ks.TotalSize, "&nbsp")).Append("</td>");
                sb.Append("<td class='AlignRight'>").Append(ks.Events).Append("</td>");
                sb.Append("<td class='AlignRight'>").Append(ks.Scavenged).Append("</td>");
                sb.Append("</tr>");
            }
            return sb.ToString();
        }

        private string RenderOverviewTable(CacheStatistics statistics, ICacheInfo[] allCaches)
        {
            List<List<CellEntry>> tableData = new List<List<CellEntry>>();

            string separator = "&nbsp";

            List<CellEntry> header = new List<CellEntry>(new CellEntry[] { "Metric", "Value" });
            tableData.Add(header);

            tableData.Add(new List<CellEntry> { "Total Entries Count", statistics.TotalCount.ToString() });

            tableData.Add(new List<CellEntry>{ "Total Caches Size",statistics.TotalSize.ToString() + separator +
                string.Format("({0})", FormatSize(statistics.TotalSize, separator))});

            long totalCachesSizeLimit = SummarizeCacheSizeLimits(allCaches);
            string totalCachesSizeLimitPresentation = string.Empty;

            if (totalCachesSizeLimit == long.MaxValue)
            {
                totalCachesSizeLimitPresentation = "Unlimited";
            }
            else
            {
                totalCachesSizeLimitPresentation = totalCachesSizeLimit + separator +
                     string.Format("({0})", FormatSize(totalCachesSizeLimit, separator));
            }

            tableData.Add(new List<CellEntry> { "Total Max Caches Size", totalCachesSizeLimitPresentation });

            tableData.Add(new List<CellEntry> { "DisableCacheSizeLimits", Settings.Caching.DisableCacheSizeLimits.ToString() });

            string html = RenderTable(tableData);

            return html;
        }

        private string RenderCacheSizeTable(ICacheInfo[] allCaches, Dictionary<string, CacheTrackState> trackSnapshot)
        {
            if (allCaches == null || allCaches.Length <= 0)
            {
                return string.Empty;
            }

            IEnumerable<ICacheInfo> caches = allCaches;

            List<List<CellEntry>> tableData = new List<List<CellEntry>>();
            List<string> rowAttributes = new List<string>();

            List<CellEntry> header = new List<CellEntry>(new [] {
                new CellEntry("Name", link: "?sort=name"),
                new CellEntry("Group", link: "?sort=group"),
                new CellEntry("Kind", link: "?sort=kind"),
                new CellEntry("Count", link: "?sort=count"),
                new CellEntry("Size", link: "?sort=size"),
                new CellEntry("MaxSize", link: "?sort=maxsize"),
                new CellEntry("Utilization,%", link: "?sort=utilization"),
                new CellEntry("Trend"),
                new CellEntry("Peak Util,%", link: "?sort=peakutil"),
                new CellEntry("Events", link: "?sort=events"),
                new CellEntry("Last Event"),
                new CellEntry("Actions"),
            });

            tableData.Add(header);

            foreach (var cache in caches)
            {
                List<CellEntry> data = new List<CellEntry>();

                string baseCssClassForData = "AlignRight";

                string separator = "&nbsp";

                string group, kind;
                ClassifyCache(cache.Name, out group, out kind);

                data.Add(cache.Name);

                // Group / Kind columns — the taxonomy the filters and summary are built on.
                data.Add(new CellEntry(group, "group-cell group-" + GroupCssSuffix(group)));
                data.Add(new CellEntry(kind == KindNamed ? "&mdash;" : kind, "kind-cell"));

                CellEntry countEntry = new CellEntry(cache.Count.ToString(), baseCssClassForData);
                data.Add(countEntry);

                CellEntry sizeEntry = new CellEntry(FormatSize(cache.Size, separator), baseCssClassForData);
                data.Add(sizeEntry);

                CellEntry maxSizeEntry = new CellEntry(FormatSize(cache.MaxSize, separator), "MaxSize " + baseCssClassForData);
                data.Add(maxSizeEntry);

                long utilizationLong = GetUtilization(cache.Size, cache.MaxSize);
                string utilizationString = utilizationLong >= 0 ? utilizationLong.ToString("#,0") + "%" : "n/a";
                string utilizationClass = utilizationLong < 80 ? "CacheUtilizationLow" : "CacheUtilizationHigh";
                CellEntry utilizationEntry = new CellEntry(utilizationString, baseCssClassForData + " " + utilizationClass);
                data.Add(utilizationEntry);

                // Tracking columns — populated from persisted state (survives reload), then
                // patched live by the client during polling. Trend is only meaningful live.
                CacheTrackState st;
                trackSnapshot.TryGetValue(cache.Name, out st);

                data.Add(new CellEntry(string.Empty, "AlignCenter trend-cell"));  // Trend (live only)

                long peakUtil = st != null ? st.PeakUtilization : utilizationLong;
                data.Add(new CellEntry(peakUtil >= 0 ? peakUtil.ToString() + "%" : "n/a", baseCssClassForData));

                int eventCount = st != null ? st.EventCount : 0;
                data.Add(new CellEntry(eventCount.ToString(), baseCssClassForData + " events-cell"));

                string lastEvent = (st != null && st.LastEventType != null) ? st.LastEventType : string.Empty;
                data.Add(new CellEntry(lastEvent, "lastevent-cell ev-" + (lastEvent.Length > 0 ? lastEvent : "none")));

                // Actions cell: a Clear button carrying the exact cache name as its POST value.
                // The name is HTML-attribute-encoded so names containing quotes/brackets are safe.
                string clearButton = string.Format(
                    "<button type='submit' name='clear' value=\"{0}\" " +
                    "onclick=\"return confirm('Clear this cache?');\">Clear</button>",
                    HttpUtility.HtmlAttributeEncode(cache.Name));

                data.Add(new CellEntry(string.Empty, "AlignCenter") { RawHtml = clearButton });

                tableData.Add(data);

                // data-cache maps JSON rows back to this <tr>; data-group/data-kind drive client
                // filtering without re-parsing the name.
                rowAttributes.Add(string.Format("data-cache=\"{0}\" data-group=\"{1}\" data-kind=\"{2}\"",
                    HttpUtility.HtmlAttributeEncode(cache.Name),
                    HttpUtility.HtmlAttributeEncode(group),
                    HttpUtility.HtmlAttributeEncode(kind)));
            }

            string html = RenderTable(tableData, "table-caches", rowAttributes);

            return html;
        }

        private void RenderCell(StringBuilder html, CellEntry entry, string elementName = "td")
        {
            if (html == null || entry == null)
                return;

            html.Append("\t<").Append(elementName);
            if (!string.IsNullOrWhiteSpace(entry.CssClass))
            {
                html.Append(" class=\"").Append(entry.CssClass).Append("\"");
            }
            html.Append('>');

            if (!string.IsNullOrEmpty(entry.RawHtml))
            {
                // Raw HTML is emitted verbatim (used for the Clear buttons).
                html.Append(entry.RawHtml);
            }
            else
            {
                if (!string.IsNullOrWhiteSpace(entry.Link))
                {
                    html.AppendFormat("<a href=\"{0}\">", entry.Link);
                }
                html.Append(entry.Value);
                if (!string.IsNullOrWhiteSpace(entry.Link))
                {
                    html.Append("</a>");
                }
            }

            html.Append("</").Append(elementName).AppendLine(">");
        }

        private string RenderTable(List<List<CellEntry>> data, string tableId = null, List<string> dataRowAttributes = null)
        {
            if (data == null || data.Count < 1)
            {
                return string.Empty;
            }

            int columns = data[0].Count;
            int rows = data.Count;

            // Header
            StringBuilder html = new StringBuilder();

            if (!string.IsNullOrWhiteSpace(tableId))
            {
                html.Append("<table id='" + tableId + "'>");
            }
            else
            {
                html.Append("<table>");
            }

            html.Append("<tr>");

            html.AppendFormat("<th>{0}</th>", "#");

            for (int i = 0; i < columns; i++)
            {
                RenderCell(html, data[0][i], "th");
            }

            html.Append("</tr>");

            // Body
            if (data.Count < 2)
            {
                html.Append("</table>");

                return html.ToString();
            }

            for (int r = 1; r < rows; r++)
            {
                // Optional per-row attribute (e.g. data-cache="...") so the client can
                // find and update this exact row in place during live tracking.
                string rowAttr = (dataRowAttributes != null && (r - 1) < dataRowAttributes.Count)
                    ? dataRowAttributes[r - 1] : null;

                if (!string.IsNullOrEmpty(rowAttr))
                {
                    html.Append("<tr ").Append(rowAttr).Append(">");
                }
                else
                {
                    html.Append("<tr>");
                }

                // Add row number
                html.AppendFormat("<td>{0}</td>", r);

                for (int c = 0; c < columns; c++)
                {
                    RenderCell(html, data[r][c]);
                }

                html.Append("</tr>");
            }

            // Footer
            html.Append("</table>");

            return html.ToString();
        }

        private string FormatSize(long size, string separator)
        {
            long num = Math.Abs(size);

            if (num < 1024)
            {
                return string.Format("{0}{1}{2}", size.ToString("#,0"), separator, "B");
            }

            if (num < 1048576)
            {
                return string.Format("{0}{1}{2}", ((double)size / 1024.0).ToString("#,0.#"), separator, "KB");
            }

            if (num < 1073741824)
            {
                return string.Format("{0}{1}{2}", ((double)size / 1048576.0).ToString("#,0.#"), separator, "MB");
            }

            return string.Format("{0}{1}{2}", ((double)size / 1073741824.0).ToString("#,0.#"), separator, "GB");
        }

        private long GetUtilization(long cacheSize, long cacheMaxSize)
        {
            if (cacheMaxSize <= 0 || cacheSize < 0)
            {
                return -1;
            }

            long utilization = 100 * cacheSize / cacheMaxSize;

            return utilization;
        }

        private long SummarizeCacheSizeLimits(ICacheInfo[] allCaches)
        {
            if (allCaches.Where(c => c.MaxSize == long.MaxValue).Any())
            {
                return long.MaxValue;
            }

            long totalMaxCachesSize = 0;

            foreach (var cache in allCaches)
            {
                totalMaxCachesSize += cache.MaxSize;
            }

            return totalMaxCachesSize;
        }

        // =====================================================================
        //  LIVE TRACKING — poll endpoint, classification, event recording.
        // =====================================================================

        // Builds the compact JSON snapshot for one poll and ends the response.
        // Diffs each cache against its previous poll state, classifies drops, and
        // records notable events. Everything runs under TrackingLock.
        private void WriteSnapshotJson()
        {
            int since;
            int.TryParse(Request.QueryString["since"], out since);

            long fullThreshold = 90;
            long parsedThreshold;
            if (long.TryParse(Request.QueryString["fullThreshold"], out parsedThreshold)
                && parsedThreshold >= 0 && parsedThreshold <= 100)
            {
                fullThreshold = parsedThreshold;
            }

            ICacheInfo[] allCaches = CacheManager.GetAllCaches();

            StringBuilder sb = new StringBuilder(64 * 1024);
            sb.Append("{\"caches\":[");

            lock (TrackingLock)
            {
                bool first = true;
                foreach (ICacheInfo cache in allCaches)
                {
                    string name = cache.Name;
                    long size = cache.Size;
                    int count = cache.Count;
                    long maxSize = cache.MaxSize;
                    long utilization = GetUtilization(size, maxSize);

                    string group, kind;
                    ClassifyCache(name, out group, out kind);

                    string trend;
                    CacheTrackState state;

                    if (!TrackStates.TryGetValue(name, out state))
                    {
                        // First time we've seen this cache — seed a baseline silently.
                        state = new CacheTrackState
                        {
                            LastSize = size,
                            LastCount = count,
                            PeakSize = size,
                            PeakUtilization = utilization
                        };
                        TrackStates[name] = state;
                        trend = "new";
                    }
                    else
                    {
                        long prevSize = state.LastSize;
                        int prevCount = state.LastCount;

                        if (size > prevSize || count > prevCount)
                        {
                            trend = "up";
                        }
                        else if (size < prevSize || count < prevCount)
                        {
                            trend = "down";

                            // Utilization right before the drop (using current maxSize, which
                            // almost never changes at runtime).
                            long utilBeforeDrop = GetUtilization(prevSize, maxSize);
                            string type = ClassifyDrop(prevCount, count, utilBeforeDrop, maxSize, fullThreshold);

                            // Only notable drops (scavenge / external clear) are logged. Ordinary
                            // shrinks (TTL / entry expiry) update state but don't flood the log.
                            if (type != null)
                            {
                                RecordEvent(state, name, type, prevSize, size, prevCount, count, maxSize, utilBeforeDrop);
                            }
                        }
                        else
                        {
                            trend = "same";
                        }

                        if (size > state.PeakSize) state.PeakSize = size;
                        if (utilization > state.PeakUtilization) state.PeakUtilization = utilization;

                        state.LastSize = size;
                        state.LastCount = count;
                    }

                    if (!first) sb.Append(',');
                    first = false;

                    // Short keys keep 1250-row payloads small. Sizes are pre-formatted with a
                    // plain space (not &nbsp) because the client writes them via textContent.
                    sb.Append("{\"n\":\"").Append(JsonEscape(name)).Append("\"");
                    sb.Append(",\"g\":\"").Append(JsonEscape(group)).Append("\"");
                    sb.Append(",\"k\":\"").Append(JsonEscape(kind)).Append("\"");
                    sb.Append(",\"c\":").Append(count);
                    sb.Append(",\"ss\":\"").Append(JsonEscape(FormatSize(size, " "))).Append("\"");
                    sb.Append(",\"mss\":\"").Append(JsonEscape(FormatSize(maxSize, " "))).Append("\"");
                    sb.Append(",\"u\":").Append(utilization);
                    sb.Append(",\"pu\":").Append(state.PeakUtilization);
                    sb.Append(",\"ec\":").Append(state.EventCount);
                    sb.Append(",\"le\":\"").Append(state.LastEventType ?? string.Empty).Append("\"");
                    sb.Append(",\"t\":\"").Append(trend).Append("\"");
                    sb.Append("}");
                }

                // Events newer than `since`. EventLog is newest-at-head; collect the new ones,
                // then reverse to chronological order so the client prepends them correctly.
                sb.Append("],\"events\":[");

                List<CacheEvent> fresh = new List<CacheEvent>();
                foreach (CacheEvent ev in EventLog)
                {
                    if (ev.Id > since) fresh.Add(ev);
                    else break; // everything past here is older than `since`
                }
                fresh.Reverse();

                bool firstEv = true;
                foreach (CacheEvent ev in fresh)
                {
                    if (!firstEv) sb.Append(',');
                    firstEv = false;

                    sb.Append("{\"id\":").Append(ev.Id);
                    sb.Append(",\"ts\":\"").Append(ev.Timestamp.ToString("HH:mm:ss")).Append("\"");
                    sb.Append(",\"n\":\"").Append(JsonEscape(ev.CacheName)).Append("\"");
                    sb.Append(",\"ty\":\"").Append(ev.Type).Append("\"");
                    sb.Append(",\"sb\":\"").Append(JsonEscape(FormatSize(ev.SizeBefore, " "))).Append("\"");
                    sb.Append(",\"sa\":\"").Append(JsonEscape(FormatSize(ev.SizeAfter, " "))).Append("\"");
                    sb.Append(",\"cb\":").Append(ev.CountBefore);
                    sb.Append(",\"ca\":").Append(ev.CountAfter);
                    sb.Append(",\"ub\":").Append(ev.UtilizationBeforeDrop);
                    sb.Append("}");
                }

                sb.Append("],\"lastEventId\":").Append(NextEventId - 1);
                sb.Append(",\"tracked\":").Append(TrackStates.Count);
                sb.Append(",\"threshold\":").Append(fullThreshold);

                // Per-Kind rollup for the live summary panel.
                sb.Append(",\"summary\":[");
                List<KindSummary> summary = BuildKindSummary(allCaches, TrackStates);
                bool firstS = true;
                foreach (KindSummary ks in summary)
                {
                    if (!firstS) sb.Append(',');
                    firstS = false;

                    sb.Append("{\"k\":\"").Append(JsonEscape(ks.Kind)).Append("\"");
                    sb.Append(",\"g\":\"").Append(JsonEscape(ks.Group)).Append("\"");
                    sb.Append(",\"caches\":").Append(ks.Caches);
                    sb.Append(",\"nonEmpty\":").Append(ks.NonEmpty);
                    sb.Append(",\"size\":\"").Append(JsonEscape(FormatSize(ks.TotalSize, " "))).Append("\"");
                    sb.Append(",\"events\":").Append(ks.Events);
                    sb.Append(",\"scavenged\":").Append(ks.Scavenged);
                    sb.Append("}");
                }
                sb.Append("]");
            }

            sb.Append("}");

            Response.Clear();
            Response.ContentType = "application/json";
            Response.Charset = "utf-8";
            Response.ContentEncoding = System.Text.Encoding.UTF8;
            Response.Cache.SetCacheability(HttpCacheability.NoCache);
            Response.Write(sb.ToString());
            Response.End();
        }

        // Classifies a decrease. Returns the event type to log, or null for an ordinary
        // shrink that isn't worth logging. Caller holds TrackingLock.
        private string ClassifyDrop(int prevCount, int newCount, long utilizationBeforeDrop, long maxSize, long fullThreshold)
        {
            // Near-total loss of entries → something called Clear() on it (publish:end, index
            // rebuild, etc.). Our own Clear button is recorded inline as ManualClear, so anything
            // reaching here that empties the cache is external.
            if (prevCount > 0 && newCount <= (int)Math.Ceiling(prevCount * 0.05))
            {
                return "ExternalClear";
            }

            // Partial drop while the cache was at/near its size limit → Sitecore trimmed it because
            // it was full. Only meaningful for size-limited caches (unlimited ones can't be "full").
            if (maxSize != long.MaxValue && maxSize > 0
                && utilizationBeforeDrop >= 0 && utilizationBeforeDrop >= fullThreshold)
            {
                return "AutoScavenged";
            }

            // Ordinary shrink (expiry / TTL). Not logged.
            return null;
        }

        // Appends an event to the log (newest-first, capped) and updates the cache's state.
        // Caller holds TrackingLock.
        private void RecordEvent(CacheTrackState state, string name, string type,
            long sizeBefore, long sizeAfter, int countBefore, int countAfter, long maxSize, long utilBeforeDrop)
        {
            CacheEvent ev = new CacheEvent
            {
                Id = NextEventId++,
                Timestamp = DateTime.Now,
                CacheName = name,
                Type = type,
                SizeBefore = sizeBefore,
                SizeAfter = sizeAfter,
                CountBefore = countBefore,
                CountAfter = countAfter,
                MaxSize = maxSize,
                UtilizationBeforeDrop = utilBeforeDrop
            };

            EventLog.AddFirst(ev);
            while (EventLog.Count > EventLogCap)
            {
                EventLog.RemoveLast();
            }

            state.LastEventType = type;
            state.LastEventTime = ev.Timestamp;
            state.EventCount++;
        }

        // Minimal JSON string escaping — enough for our flat DTOs, avoids taking a dependency on
        // System.Web.Extensions / JavaScriptSerializer which may not load on a locked-down server.
        private static string JsonEscape(string s)
        {
            if (string.IsNullOrEmpty(s)) return string.Empty;

            StringBuilder sb = new StringBuilder(s.Length + 8);
            foreach (char ch in s)
            {
                switch (ch)
                {
                    case '\"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\b': sb.Append("\\b"); break;
                    case '\f': sb.Append("\\f"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        // Escape control chars AND everything above ASCII, so the emitted JSON is
                        // pure ASCII and immune to charset mis-negotiation on the wire.
                        if (ch < ' ' || ch > '~')
                            sb.Append("\\u").Append(((int)ch).ToString("x4"));
                        else
                            sb.Append(ch);
                        break;
                }
            }
            return sb.ToString();
        }

        private string RenderTrackingControls()
        {
            // Current max event id, so the client starts its live log from "now" instead of
            // replaying persisted history (the per-row Events/Last Event columns already carry it).
            int currentMaxEventId;
            lock (TrackingLock)
            {
                currentMaxEventId = NextEventId - 1;
            }

            StringBuilder sb = new StringBuilder();

            sb.Append("<div class='tracking-controls'>");
            sb.Append("<button type='button' id='btn-track' onclick='toggleTracking()'>Start tracking</button>");
            sb.Append("&nbsp;&nbsp;Interval:&nbsp;");
            sb.Append("<select id='track-interval'>");
            sb.Append("<option value='1'>1s</option>");
            sb.Append("<option value='3' selected>3s</option>");
            sb.Append("<option value='5'>5s</option>");
            sb.Append("<option value='10'>10s</option>");
            sb.Append("</select>");
            sb.Append("&nbsp;&nbsp;&quot;Full&quot; threshold&nbsp;%:&nbsp;");
            sb.Append("<input type='number' id='track-threshold' value='90' min='1' max='100' style='width:60px'>");
            sb.Append("&nbsp;&nbsp;<button type='submit' name='reset' value='1' class='reset-stats' ");
            sb.Append("onclick=\"return confirm('Reset all tracking statistics and the event log?');\">Reset stats</button>");
            // NOTE: the current sort is preserved by the single hidden 'sort' field rendered in
            // RenderFilterComponent. Both controls live in the same <form>, so one field covers
            // every submit button (reset / clear / clear-all). Do NOT add a second one here —
            // duplicate same-named fields make Request["sort"] a comma-joined value and break sorting.
            sb.Append("<span id='track-status' class='track-status'>Idle &mdash; not tracking.</span>");
            sb.Append("</div>");

            sb.Append("<div class='event-log-wrap'>");
            sb.Append("<div class='event-log-head'>Event Log <span id='event-log-count'>(0)</span> &mdash; newest first. ");
            sb.Append("Watch for <b class='ev-AutoScavenged'>AutoScavenged</b> (cache too small &rarr; Sitecore trimmed it) and ");
            sb.Append("<b class='ev-ExternalClear'>ExternalClear</b>. Click an entry to jump to its row.</div>");
            sb.Append("<div id='event-log' class='event-log' data-last-event-id='" + currentMaxEventId + "'></div>");
            sb.Append("</div>");

            return sb.ToString();
        }
    </script>

    <link rel="shortcut icon" type="image/png" href="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADgAAAA4CAQAAAACj/OVAAAAAmJLR0QA/4ePzL8AAAAJcEhZcwAALiMAAC4jAXilP3YAAAAHdElNRQfiBwcLISbqaIt/AAAHTUlEQVRYw+2Ye1TT1x3Ab/LL+4GEAMEmMF4BIWiqAopiwQqzSG2rm1urdVbmPJ16Rh+nqEwTAiKzW3Vnczo5s+vOejpPravoQURbHiLFEYigkXcrD8MjAZIQQh7k97v7A+X3kwTIz/LPdnrzT+69v3s/9/u4936/F4Afyv96oXj7oSLEHjsRpl/Tts4igqypNuYI1yitDapkPWI9UA0uIPBofMcu3fIBOcrz3E83iTXBDeFnVd0LADy0vi6/dwVkAeo8H6JUa9xXcUXHG74HUBGuOda2ybXIW7VDyBl4/lJUgcow+zfI7F3ZWeVne1Oe2Msr+1Bc/EfxA+k7hmrbSQLz/MIPlhfZRRQKaTekWhe3Z7xuUatJqFQpai1U75gpG4SIjTnCMwTqgpumWrpWGwMn/G3+kDFzYYgl5eTHeV4ClQEPfteQNbOVpV9SHnJbcF3VO8PO0fpN3amd61H+TCd68ZgnpAdglqoyhygdhIg1/qL0bKF6Ni3mCe3y5uy2dIxFlBSxbMw9c3peE+zfF2YPhcRf8u2DGd4Y793d8ranR0aMf7BlHqdRxJadcQoJ0mGyq2t/fbzeG+Cdpl/VGhItQbiUkDEs3XO52joHkHtat4YwAFtTvOydfJ23DnprMOtrh3Q4Ep/BGsjma0tnHZDzasQYUSWbSpT+ZHeFIjJJQ5wjeih31awS2v9tleCuIq5fuy+/jyywenRHf1+Cw+9J3cWhCts/J2xT/O/htNEwwkqs61QFHWRxv03e8mn35uRPgAM/fbTpCplHYMubGGEzxJafKCMHO7r0zT9dKL37RsPrNINEg7dj3I69HoBHl/Ym4sammZd9RAaWJ3z7vauXavajPoCK8huzEs5RnDhDt1wpcQNapUYpbr/Ya8fryAAfHr5xzCSlPJ5Nl4AJQm/jvYNL7dFuQFMioE3bzxZaRU6dQjXVQTzAm18OqQeuJ9VJX1uYG7D1Jfx7htG3ghzQ54agi1gfCfU1McYIMqa4AYei8G6mKb+LHDDPKGkl1q2L0QmaieCQqdPeMe1LbIKCBgHpIrl3F3B13NHHmwFDTBzzBL6AADcgsUR9U0EaSLMDsKGANuLkTNV5LT6mYfxMZs4JfNaC0W6etARP/V/3e+hxbupCwVrSAMrotwrnjUAWBqcUGULZeoSBcaaPNAxAr4Fdq8kCR14zR0ZW6ZNw7TIMI4SbhmJ3A1JteLcxkKx8jW9Byo807dNAZJw77iL4veCRG1DQQ9hF/rmv4aff/OXbIwMJ0koHfUhOsUEIAAA+OoRJDKCltW5AeQne7RSMhU+keIs78E7dL/xa5Z/WHgAw8/3o6xADQNhjEDsJwKBKN6Av4exD2T0JkwGKaG9w+94vU3GHNpyo3zPhn1ZIZcsuZB4UamXXe5Lwy51uZPW5Abmdgk780mzJRAyd7yoD5gsnfnr+WqGwc2New87u1Jgy1uiVD7/82Bjx4w/oA32EwCJYzbrvBiy4H1IPpx0Z5Wu3CzoMu+fCHdxc+kXT1uVfrC9o2P1wQ+C92Iu3DwAEIOo37P53siEDD4nFTXh6Q4hpto4/2Abo054qjinrWZsWlmFaF3qr/2nUkRXLNjP/cndnxDfJp5iWr/INsiXX44trckbiAABg1Xk6aNyOn2HU8dSsarPHyDuxSS/HL+GgxpSim0UrLwVWGJOEN4/dAUApwqTG1aYQu4g2GXiL0zUZ1rC9bxVEkosX19QcGlgJAISLm1MUZSfHIvF55F9e+cksof6hFy9eJuYI4VUr/3ztD6JvEz/q36CPE/YJ1MgYMok4nDzUryej9QUXnz0YUR1z2RRVkYPyAYDQ//76oqqjw7H4HOz+La8Sk9QZuUXmBe3PiIFw0vmQ0pJixCkrjSh3sPQvtKSZxRQU5QHAGpZol3zO7zTHN2f2J05ZLKgp+cS9Xe0bCRkGmnTmX7+ZI5lRRJdcNUuJoX7ErYRTHduat2B08b24K1wtfQxAmtXFw+hOUfcrLamTiyCVQgGAZkr4Z8iN6oIBOTGhETVkpOeZ5syesrOunMFvr6lBa/7q4NbtH5VSKABlmCkYx2T1c7HwgxpgYnXCOciqyjY/tXdp5q27PiyZN13bc6TiMGEyACFii6qM+zvmp9lmlliec/GmfRuljXP7gzpkZYhB8/Z3yTPSNXNGzulirzLgn5/7z163NMsSc03cKGxx8C1BLt6kDwD0Mdo4b5jpMAY/TO1MI4YoJBNSAJSiNlX9TsiZmXJTnOxhpkmgl7SzzQDYFj2KNopsfg6Bh5TbnPJHr1Pux4rNrcxFuc92HdPML3lQ5jzPJpqa3T16qS0AkH3HQEWajPdOffYM7zR19/deQvxHxS6Ot48nEHJ0if9Y/cvC5u/x9JW7SpujTcc4cy1tSjJkXPb10uOFjQvwuKeQffdWb/zA85O+nvsZI5LG0Prgv6l6FvD5UvmcPcYu0ad0r7D6jT2OPX36uKOhmsBKdh/zwVzvaz+U/6/yX1fT8r2+aaBbAAAAAElFTkSuQmCC">
</head>
<body>
    <form method="post">
        <div id="Header" runat="server">
        </div>
        <div id="Status" runat="server">
        </div>
        <div id="Totals" runat="server">
        </div>
        <div id="Tracking" runat="server">
        </div>
        <div id="Summary" runat="server">
        </div>
        <div id="Caches" runat="server">
        </div>
    </form>

    <script>
        // ================= Live cache tracking (client) =================
        // Polls ?ajax=snapshot on an interval, patches existing rows in place (never
        // re-sorts — that would make 1250 rows jump), flashes changes, and appends
        // notable drops to the event log. All classification is done server-side.
        (function () {
            var tracking = false;
            var timer = null;
            var inFlight = false;
            var lastEventId = 0;
            var pollCount = 0;
            var rowMap = {};   // exact cache name -> <tr>
            var tableBody = null;

            var LS_INTERVAL = "cacheAdmin-interval";
            var LS_THRESHOLD = "cacheAdmin-threshold";
            var LS_NAME = "cacheAdmin-cacheName";
            var LS_KINDS = "cacheAdmin-kindsOff";     // JSON array of DISABLED kinds
            var LS_GROUPS = "cacheAdmin-groupsOff";   // JSON array of DISABLED groups
            var LS_HIDE_EMPTY = "cacheAdmin-hideEmpty";
            var LS_ONLY_EVENTS = "cacheAdmin-onlyEvents";
            var EVENT_DOM_CAP = 300;

            var FLASH_MS = 1500;

            // Column indices in the caches table (td[0] is the leading "#" cell).
            var COL = { name: 1, group: 2, kind: 3, count: 4, size: 5, maxsize: 6,
                        util: 7, trend: 8, peakutil: 9, events: 10, lastevent: 11, actions: 12 };

            // Filter state.
            var groupEnabled = {};   // group name -> bool
            var kindEnabled = {};    // kind name  -> bool
            var hideEmpty = false;
            var onlyEvents = false;
            var nameFilter = "";

            function q(id) { return document.getElementById(id); }

            function buildRowMap() {
                rowMap = {};
                var table = q("table-caches");
                if (!table) { return; }
                tableBody = table.tBodies.length ? table.tBodies[0] : table;
                var rows = table.querySelectorAll("tr[data-cache]");
                for (var i = 0; i < rows.length; i++) {
                    rowMap[rows[i].getAttribute("data-cache")] = rows[i];
                }
            }

            function setText(td, val) {
                if (td && td.textContent !== String(val)) { td.textContent = val; }
            }

            function flash(tr, cls) {
                if (!tr) { return; }
                tr.classList.remove("flash-up", "flash-shrink", "flash-clear");
                // Force reflow so re-adding the same class re-triggers the highlight.
                void tr.offsetWidth;
                tr.classList.add(cls);
                if (tr._flashTimer) { clearTimeout(tr._flashTimer); }
                tr._flashTimer = setTimeout(function () {
                    tr.classList.remove("flash-up", "flash-shrink", "flash-clear");
                    tr._flashTimer = null;
                }, FLASH_MS);
            }

            // Glyphs are built from decimal code points (pure-ASCII source) so they render
            // correctly no matter how the page/transport charset is negotiated.
            var GLYPH_UP = String.fromCharCode(9650);    // U+25B2 black up triangle
            var GLYPH_DOWN = String.fromCharCode(9660);  // U+25BC black down triangle
            var GLYPH_NEW = String.fromCharCode(8226);   // U+2022 bullet
            var GLYPH_ARROW = String.fromCharCode(8594); // U+2192 rightwards arrow
            var GLYPH_DASH = String.fromCharCode(8212);  // U+2014 em dash (for "named" kind)

            function trendSymbol(t) {
                if (t === "up") { return GLYPH_UP; }
                if (t === "down") { return GLYPH_DOWN; }
                if (t === "new") { return GLYPH_NEW; }
                return "";
            }

            function groupClass(g) {
                if (g === "Content site") { return "content"; }
                if (g === "System site") { return "system"; }
                if (g === "Database") { return "db"; }
                return "named";
            }

            function appendRow(c) {
                var table = q("table-caches");
                if (!table) { return null; }
                if (!tableBody) { tableBody = table.tBodies.length ? table.tBodies[0] : table; }

                var tr = document.createElement("tr");
                tr.setAttribute("data-cache", c.n);
                tr.setAttribute("data-group", c.g);
                tr.setAttribute("data-kind", c.k);

                // # | Name | Group | Kind | Count | Size | MaxSize | Util | Trend | PeakUtil | Events | LastEvent | (Actions)
                var cells = [
                    { t: "*", cls: "" },
                    { t: c.n, cls: "" },
                    { t: c.g, cls: "group-cell group-" + groupClass(c.g) },
                    { t: (c.k === "named" ? GLYPH_DASH : c.k), cls: "kind-cell" },
                    { t: c.c, cls: "AlignRight" },
                    { t: c.ss, cls: "AlignRight" },
                    { t: c.mss, cls: "MaxSize AlignRight" },
                    { t: (c.u < 0 ? "n/a" : c.u + "%"), cls: "AlignRight" },
                    { t: "", cls: "AlignCenter trend-cell" },
                    { t: (c.pu < 0 ? "n/a" : c.pu + "%"), cls: "AlignRight" },
                    { t: c.ec, cls: "AlignRight events-cell" },
                    { t: (c.le || ""), cls: "lastevent-cell ev-" + (c.le || "none") }
                ];
                for (var i = 0; i < cells.length; i++) {
                    var td = document.createElement("td");
                    if (cells[i].cls) { td.className = cells[i].cls; }
                    td.textContent = cells[i].t;
                    tr.appendChild(td);
                }

                // Actions cell: a real Clear submit button (safe DOM construction, no injection).
                var actionTd = document.createElement("td");
                actionTd.className = "AlignCenter";
                var btn = document.createElement("button");
                btn.type = "submit";
                btn.name = "clear";
                btn.value = c.n;
                btn.textContent = "Clear";
                btn.onclick = function () { return confirm("Clear this cache?"); };
                actionTd.appendChild(btn);
                tr.appendChild(actionTd);

                tableBody.appendChild(tr);
                rowMap[c.n] = tr;
                return tr;
            }

            function applyCache(c, eventSet) {
                var tr = rowMap[c.n];
                if (!tr) { tr = appendRow(c); if (!tr) { return; } }

                var tds = tr.children;
                setText(tds[COL.count], c.c);
                setText(tds[COL.size], c.ss);
                setText(tds[COL.util], c.u < 0 ? "n/a" : c.u + "%");

                var trendTd = tds[COL.trend];
                setText(trendTd, trendSymbol(c.t));
                trendTd.className = "AlignCenter trend-cell" +
                    (c.t === "up" ? " trend-up" : (c.t === "down" ? " trend-down" : ""));

                setText(tds[COL.peakutil], c.pu < 0 ? "n/a" : c.pu + "%");
                setText(tds[COL.events], c.ec);

                setText(tds[COL.lastevent], c.le || "");
                tds[COL.lastevent].className = "lastevent-cell ev-" + (c.le || "none");

                if (c.t === "up") {
                    flash(tr, "flash-up");
                } else if (c.t === "down") {
                    // A notable drop this tick (scavenge / clear) flashes red; a minor shrink orange.
                    flash(tr, eventSet[c.n] ? "flash-clear" : "flash-shrink");
                }
            }

            // -------- Filtering (name + group + kind + state), all ANDed together --------
            function applyFilters() {
                var table = q("table-caches");
                if (!table) { return; }
                var rows = table.querySelectorAll("tr[data-cache]");
                var nf = nameFilter.toUpperCase();
                var shown = 0;

                for (var i = 0; i < rows.length; i++) {
                    var tr = rows[i];
                    var visible = true;

                    var group = tr.getAttribute("data-group");
                    var kind = tr.getAttribute("data-kind");

                    if (groupEnabled[group] === false) { visible = false; }
                    if (visible && kindEnabled[kind] === false) { visible = false; }
                    if (visible && nf) {
                        var name = tr.getAttribute("data-cache") || "";
                        if (name.toUpperCase().indexOf(nf) === -1) { visible = false; }
                    }
                    if (visible && (hideEmpty || onlyEvents)) {
                        var tds = tr.children;
                        if (hideEmpty && (parseInt(tds[COL.count].textContent, 10) || 0) <= 0) { visible = false; }
                        if (visible && onlyEvents && (parseInt(tds[COL.events].textContent, 10) || 0) <= 0) { visible = false; }
                    }

                    tr.style.display = visible ? "" : "none";
                    if (visible) { shown++; }
                }

                var vc = q("filter-visible-count");
                if (vc) { vc.textContent = "showing " + shown + " of " + rows.length; }
            }

            function readCheckboxStates() {
                groupEnabled = {}; kindEnabled = {};
                var g = document.querySelectorAll(".grp-cb");
                for (var i = 0; i < g.length; i++) { groupEnabled[g[i].getAttribute("data-group")] = g[i].checked; }
                var k = document.querySelectorAll(".kind-cb");
                for (var j = 0; j < k.length; j++) { kindEnabled[k[j].getAttribute("data-kind")] = k[j].checked; }
            }

            function syncKindCheckboxes() {
                var k = document.querySelectorAll(".kind-cb");
                for (var i = 0; i < k.length; i++) {
                    var name = k[i].getAttribute("data-kind");
                    if (kindEnabled[name] !== undefined) { k[i].checked = kindEnabled[name]; }
                }
            }

            function syncGroupCheckboxes() {
                var g = document.querySelectorAll(".grp-cb");
                for (var i = 0; i < g.length; i++) {
                    var name = g[i].getAttribute("data-group");
                    if (groupEnabled[name] !== undefined) { g[i].checked = groupEnabled[name]; }
                }
            }

            function setAllKinds(v) { for (var k in kindEnabled) { kindEnabled[k] = v; } syncKindCheckboxes(); }
            function setAllGroups(v) { for (var g in groupEnabled) { groupEnabled[g] = v; } syncGroupCheckboxes(); }

            function persistFilters() {
                var offKinds = [], offGroups = [];
                for (var k in kindEnabled) { if (!kindEnabled[k]) { offKinds.push(k); } }
                for (var g in groupEnabled) { if (!groupEnabled[g]) { offGroups.push(g); } }
                localStorage.setItem(LS_KINDS, JSON.stringify(offKinds));
                localStorage.setItem(LS_GROUPS, JSON.stringify(offGroups));
                localStorage.setItem(LS_HIDE_EMPTY, hideEmpty ? "1" : "0");
                localStorage.setItem(LS_ONLY_EVENTS, onlyEvents ? "1" : "0");
            }

            function parseArr(key) {
                var v = localStorage.getItem(key);
                if (v === null) { return null; }
                try { var a = JSON.parse(v); return Array.isArray(a) ? a : null; } catch (e) { return null; }
            }

            function restoreFilters() {
                // Start from the server-rendered checkbox defaults (xsl/viewstate/registry off).
                readCheckboxStates();

                var offKinds = parseArr(LS_KINDS);
                if (offKinds) {
                    for (var k in kindEnabled) { kindEnabled[k] = true; }
                    for (var i = 0; i < offKinds.length; i++) { kindEnabled[offKinds[i]] = false; }
                    syncKindCheckboxes();
                }
                var offGroups = parseArr(LS_GROUPS);
                if (offGroups) {
                    for (var g in groupEnabled) { groupEnabled[g] = true; }
                    for (var j = 0; j < offGroups.length; j++) { groupEnabled[offGroups[j]] = false; }
                    syncGroupCheckboxes();
                }

                hideEmpty = localStorage.getItem(LS_HIDE_EMPTY) === "1";
                onlyEvents = localStorage.getItem(LS_ONLY_EVENTS) === "1";
                var he = q("cb-hide-empty"); if (he) { he.checked = hideEmpty; }
                var oe = q("cb-only-events"); if (oe) { oe.checked = onlyEvents; }

                var nf = q("input-filter");
                var savedName = localStorage.getItem(LS_NAME);
                if (nf && savedName) { nf.value = savedName; nameFilter = savedName; }
            }

            function applyPreset(p) {
                if (p === "all") { setAllKinds(true); setAllGroups(true); }
                else if (p === "never-used") {
                    kindEnabled["xsl"] = false; kindEnabled["viewstate"] = false; kindEnabled["registry"] = false;
                    syncKindCheckboxes();
                }
                else if (p === "content") { setAllGroups(false); groupEnabled["Content site"] = true; syncGroupCheckboxes(); }
                else if (p === "db") { setAllGroups(false); groupEnabled["Database"] = true; syncGroupCheckboxes(); }
                else if (p === "named") { setAllGroups(false); groupEnabled["Named"] = true; syncGroupCheckboxes(); }
                persistFilters();
                applyFilters();
            }

            function escHtml(s) {
                return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
            }

            function buildSummary(summary) {
                var tb = q("summary-tbody");
                if (!tb || !summary) { return; }
                var rows = "";
                for (var i = 0; i < summary.length; i++) {
                    var s = summary[i];
                    var kindLabel = (s.k === "named") ? "named" : s.k;
                    rows += "<tr><td>" + escHtml(kindLabel) + "</td>" +
                        "<td class='group-" + groupClass(s.g) + "'>" + escHtml(s.g) + "</td>" +
                        "<td class='AlignRight'>" + s.caches + "</td>" +
                        "<td class='AlignRight'>" + s.nonEmpty + "</td>" +
                        "<td class='AlignRight'>" + escHtml(s.size) + "</td>" +
                        "<td class='AlignRight'>" + s.events + "</td>" +
                        "<td class='AlignRight'>" + s.scavenged + "</td></tr>";
                }
                tb.innerHTML = rows;
            }

            function addEvents(events) {
                var log = q("event-log");
                if (!log) { return; }

                // events arrive oldest-first; prepend each so newest ends up on top.
                for (var i = 0; i < events.length; i++) {
                    var ev = events[i];
                    var div = document.createElement("div");
                    div.className = "ev ev-" + ev.ty;
                    div.setAttribute("data-cache", ev.n);

                    var detail;
                    if (ev.n === "(all caches)") {
                        detail = "ManualClear - cleared " + ev.cb + " caches";
                    } else {
                        detail = ev.ty + ": " + ev.n +
                            "  (" + ev.cb + GLYPH_ARROW + ev.ca + " entries, " + ev.sb + " " + GLYPH_ARROW + " " + ev.sa;
                        if (ev.ub >= 0) { detail += ", " + ev.ub + "% full before"; }
                        detail += ")";
                    }
                    div.textContent = "[" + ev.ts + "] " + detail;
                    div.title = "Click to jump to this cache's row";
                    (function (name) {
                        div.onclick = function () { jumpToRow(name); };
                    })(ev.n);

                    log.insertBefore(div, log.firstChild);
                }

                while (log.children.length > EVENT_DOM_CAP) {
                    log.removeChild(log.lastChild);
                }
                var cnt = q("event-log-count");
                if (cnt) { cnt.textContent = "(" + log.children.length + ")"; }
            }

            function jumpToRow(name) {
                var tr = rowMap[name];
                if (!tr) { return; }
                tr.style.display = "";           // un-hide if the filter had hidden it
                tr.scrollIntoView({ block: "center", behavior: "smooth" });
                flash(tr, "flash-clear");
            }

            function poll() {
                if (!tracking || inFlight) { return; }
                inFlight = true;

                var thrEl = q("track-threshold");
                var thr = (thrEl && thrEl.value) ? thrEl.value : "90";

                fetch("?ajax=snapshot&since=" + lastEventId + "&fullThreshold=" + encodeURIComponent(thr),
                      { cache: "no-store" })
                    .then(function (r) {
                        if (!r.ok) { throw new Error("HTTP " + r.status); }
                        return r.json();
                    })
                    .then(function (data) {
                        pollCount++;

                        var eventSet = {};
                        if (data.events) {
                            for (var i = 0; i < data.events.length; i++) {
                                eventSet[data.events[i].n] = true;
                            }
                        }

                        for (var j = 0; j < data.caches.length; j++) {
                            applyCache(data.caches[j], eventSet);
                        }

                        if (data.events && data.events.length) { addEvents(data.events); }
                        lastEventId = data.lastEventId;

                        buildSummary(data.summary);
                        // Re-apply filters so live count/events changes (and any appended rows)
                        // respect the current Hide-empty / Only-with-events / kind / group choices.
                        applyFilters();

                        var st = q("track-status");
                        if (st) {
                            st.textContent = "Tracking... polls: " + pollCount +
                                ", caches: " + data.caches.length +
                                ", tracked: " + data.tracked +
                                ", total events: " + lastEventId;
                        }
                    })
                    .catch(function (e) {
                        var st = q("track-status");
                        if (st) { st.textContent = "Poll error: " + e.message + " (still trying)"; }
                    })
                    .then(function () { inFlight = false; }); // always clears the in-flight guard
            }

            function startTracking() {
                tracking = true;
                var btn = q("btn-track");
                btn.textContent = "Stop tracking";
                btn.classList.add("tracking-on");

                var ivEl = q("track-interval");
                var iv = parseInt(ivEl.value, 10) || 3;
                localStorage.setItem(LS_INTERVAL, iv);
                localStorage.setItem(LS_THRESHOLD, q("track-threshold").value);

                poll(); // fire immediately, then on the interval
                timer = setInterval(poll, iv * 1000);
            }

            function stopTracking() {
                tracking = false;
                var btn = q("btn-track");
                btn.textContent = "Start tracking";
                btn.classList.remove("tracking-on");
                if (timer) { clearInterval(timer); timer = null; }
                var st = q("track-status");
                if (st) { st.textContent = "Stopped after " + pollCount + " polls."; }
            }

            // Exposed globally for the inline onclick on the Start/Stop button.
            window.toggleTracking = function () {
                if (tracking) { stopTracking(); } else { startTracking(); }
            };

            function wireFilters() {
                var i;
                var grp = document.querySelectorAll(".grp-cb");
                for (i = 0; i < grp.length; i++) {
                    grp[i].addEventListener("change", function () {
                        groupEnabled[this.getAttribute("data-group")] = this.checked;
                        persistFilters(); applyFilters();
                    });
                }
                var kinds = document.querySelectorAll(".kind-cb");
                for (i = 0; i < kinds.length; i++) {
                    kinds[i].addEventListener("change", function () {
                        kindEnabled[this.getAttribute("data-kind")] = this.checked;
                        persistFilters(); applyFilters();
                    });
                }
                var he = q("cb-hide-empty");
                if (he) { he.addEventListener("change", function () { hideEmpty = this.checked; persistFilters(); applyFilters(); }); }
                var oe = q("cb-only-events");
                if (oe) { oe.addEventListener("change", function () { onlyEvents = this.checked; persistFilters(); applyFilters(); }); }

                var presets = document.querySelectorAll(".preset");
                for (i = 0; i < presets.length; i++) {
                    presets[i].addEventListener("click", function () { applyPreset(this.getAttribute("data-preset")); });
                }

                var nf = q("input-filter");
                if (nf) {
                    nf.addEventListener("input", function () {
                        nameFilter = this.value;
                        localStorage.setItem(LS_NAME, nameFilter);
                        applyFilters();
                    });
                    // Enter in a text field would implicitly submit the form (and fire the first
                    // submit button — Reset stats). Suppress it; all actions are explicit clicks.
                    nf.addEventListener("keydown", function (e) { if (e.key === "Enter") { e.preventDefault(); } });
                }
            }

            document.addEventListener("DOMContentLoaded", function () {
                buildRowMap();

                // Start the live log from the current server event id, so a reload doesn't
                // replay persisted history into the panel (the row columns already show it).
                var logEl = q("event-log");
                if (logEl) {
                    var seed = parseInt(logEl.getAttribute("data-last-event-id"), 10);
                    if (!isNaN(seed)) { lastEventId = seed; }
                }

                var ivEl = q("track-interval");
                var thrEl = q("track-threshold");

                var savedIv = localStorage.getItem(LS_INTERVAL);
                if (savedIv && ivEl) { ivEl.value = savedIv; }
                var savedThr = localStorage.getItem(LS_THRESHOLD);
                if (savedThr && thrEl) { thrEl.value = savedThr; }

                if (ivEl) {
                    ivEl.addEventListener("change", function () {
                        localStorage.setItem(LS_INTERVAL, this.value);
                        if (tracking) { stopTracking(); startTracking(); } // apply new interval live
                    });
                }
                if (thrEl) {
                    thrEl.addEventListener("change", function () {
                        localStorage.setItem(LS_THRESHOLD, this.value);
                    });
                    // Don't let Enter in the threshold field implicitly submit the form.
                    thrEl.addEventListener("keydown", function (e) { if (e.key === "Enter") { e.preventDefault(); } });
                }

                // Restore + wire the group/kind/state filters, then apply them once so the
                // default-hidden kinds (xsl/viewstate/registry) are hidden on first load.
                restoreFilters();
                wireFilters();
                applyFilters();

                // Deliberately NOT auto-starting — tracking is opt-in.
            });
        })();
    </script>
</body>
</html>

<%@ Page Language="C#" AutoEventWireup="true" Debug="false" %>

<%@ Import Namespace="Sitecore.Configuration" %>
<%@ Import Namespace="Sitecore.Data" %>
<%@ Import Namespace="System.Linq" %>
<%@ Import Namespace="System.Web" %>
<%@ Import Namespace="System.Data" %>
<%@ Import Namespace="System.Data.SqlClient" %>

<script runat="server">
    // =====================================================================
    //  SECURITY GATE — copied verbatim from CacheAdmin.aspx. See CLAUDE.md
    //  "Conventions for future tools in this folder": copy this into any
    //  new diagnostic page before adding functionality. Do not modify.
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

        if (System.Net.IPAddress.IsLoopback(remoteIp))
        {
            return true;
        }

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
    <title>EventQueue Monitor</title>
    <meta content="C#" name="CODE_LANGUAGE">
    <!-- No external dependencies: vanilla JS only, fully self-contained single file. -->

    <style type="text/css">
        body {
            font-family: 'Open Sans', sans-serif;
        }

        div {
            padding: 10px 20px;
        }

        table {
            border-collapse: collapse;
            margin-bottom: 10px;
        }

        table, th, td {
            border: 1px solid black;
            padding: 5px;
            font-size: 13px;
        }

        th {
            background-color: #F5F5F5;
        }

        td.AlignRight {
            text-align: right;
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

        .db-panel, .controls-panel {
            background-color: #eef3f8;
            border: 1px solid #cfd8dc;
        }

        .conn-summary {
            color: #333;
        }

        .instance-name {
            color: #555;
            font-style: italic;
        }

        .poll-status {
            margin-left: 15px;
            font-style: italic;
            color: #555;
        }

        button {
            cursor: pointer;
        }

        .eqstamp-head, .events-head {
            padding: 0 0 6px 0;
            font-size: 13px;
            color: #444;
        }

        .events-footer {
            padding: 8px 0 0 0;
            font-size: 12px;
            color: #555;
            border-top: 1px dashed #ccc;
            margin-top: 4px;
        }

        tr.eq-mine td {
            background-color: #fff9c4;
        }

        .ev-publish { color: #0d47a1; font-weight: bold; }
        .ev-saved   { color: #1b5e20; }
        .ev-deleted { color: #b71c1c; }
        .ev-other   { color: #555; }

        td.instance-type {
            color: #777;
            font-size: 12px;
        }

        tr.flash-new td {
            background-color: #c8e6c9 !important;
            transition: background-color 1.4s ease;
        }
    </style>

    <script runat="server">
        // ===================== DTOs =====================
        public class DbCandidate
        {
            public string Name;
            public string ConnectionString;
            public string DataSource;
            public string InitialCatalog;
        }

        public class EventRow
        {
            public string EventType;
            public string InstanceType;
            public DateTime Created;
            public long Stamp;
            public long PayloadBytes;
        }

        public class EqStampRow
        {
            public string Key;
            public string RawValue;
            public long? StampValue;
            public bool IsCurrentMachine;
        }

        // Overview of the whole EventQueue table, independent of the top-N window shown above.
        // Exists specifically to catch Sitecore's cleanup agent purging events too aggressively -
        // if a CD's EQSTAMP is older than OldestCreated, the events it still needs are already gone.
        public class QueueStats
        {
            public long TotalCount;
            public bool HasAny;
            public long OldestStamp;
            public DateTime OldestCreated;
        }

        private static readonly HashSet<string> DefaultExcludedFromAutoSelect =
            new HashSet<string>(new[] { "core", "master" }, StringComparer.OrdinalIgnoreCase);

        // How far behind the current head stamp an instance must be before its EQSTAMP row is
        // considered stale enough to offer deletion. Kept in sync with the client-side
        // STALE_THRESHOLD constant in the poll script — if you change one, change both.
        private const int EqStampStaleThreshold = 100;

        // Delete is only offered for rows that look safely stale:
        //  - never for the current machine's own row (the one clear self-inflicted mistake),
        //  - always for a row whose Value isn't even a valid stamp (clearly garbage/legacy),
        //  - otherwise only once it's more than EqStampStaleThreshold behind the current head,
        //  - and — since the "show all Properties rows" debug toggle can list totally unrelated
        //    Sitecore properties — only for keys that actually look like an EQSTAMP entry, so an
        //    unrelated property never grows a tempting Delete button just because it's not numeric.
        private bool CanOfferDelete(EqStampRow row, long headStamp, bool haveHeadStamp)
        {
            if (row.IsCurrentMachine) return false;
            if (row.Key.IndexOf("EQStamp", StringComparison.OrdinalIgnoreCase) < 0) return false;
            if (!row.StampValue.HasValue) return true;
            if (!haveHeadStamp) return false;
            return (headStamp - row.StampValue.Value) > EqStampStaleThreshold;
        }

        protected void Page_Load(object sender, EventArgs e)
        {
            Response.ContentEncoding = System.Text.Encoding.UTF8;
            Response.Charset = "utf-8";

            // ---- Live-poll endpoint: compact JSON, ends before any HTML is built. Covered by
            //      the same Page_PreInit localhost gate as everything else on this page. ----
            if (Request.QueryString["ajax"] == "snapshot")
            {
                WriteSnapshotJson();
                return;
            }

            // Discover which configured databases actually have a working [EventQueue] table.
            // This is empirical (opens a real connection and queries), not a guess — it's what
            // makes the "which database" question self-answering instead of hardcoded, and works
            // identically whether this copy is running on a CD (web) or the preview server.
            List<DbCandidate> candidates = DiscoverEventQueueDatabases();

            string requestedDb = Request["db"];
            DbCandidate selected = candidates.FirstOrDefault(c => string.Equals(c.Name, requestedDb, StringComparison.OrdinalIgnoreCase));
            if (selected == null)
            {
                selected = candidates.FirstOrDefault(c => !DefaultExcludedFromAutoSelect.Contains(c.Name))
                           ?? candidates.FirstOrDefault();
            }

            string statusMessage = null;
            bool statusIsError = false;

            // Handle EQSTAMP delete (POST only).
            if (string.Equals(Request.HttpMethod, "POST", StringComparison.OrdinalIgnoreCase))
            {
                string deleteKey = Request.Form["deleteKey"];
                if (!string.IsNullOrEmpty(deleteKey))
                {
                    if (selected == null)
                    {
                        statusIsError = true;
                        statusMessage = "Cannot delete: no valid database selected.";
                    }
                    else
                    {
                        statusMessage = DeleteEqStamp(selected, deleteKey, out statusIsError);
                    }
                }
            }

            string pageVersion = "1.3.0 (localhost-only, read-only SQL diagnostics + guarded EQSTAMP cleanup)";
            Header.InnerHtml = string.Format("<h2>{0}</h2><h6>Version:&nbsp;{1}</h6>",
                "Sitecore EventQueue Monitor", pageVersion);

            if (statusMessage != null)
            {
                Status.InnerHtml = string.Format("<div class='status{0}'>{1}</div>",
                    statusIsError ? " error" : "", statusMessage);
            }

            if (candidates.Count == 0)
            {
                DbInfo.InnerHtml = "<div class='status error'>No configured database has a working " +
                    "[EventQueue] table. Checked: " +
                    HttpUtility.HtmlEncode(string.Join(", ", Factory.GetDatabaseNames())) + "</div>";
                return;
            }

            DbInfo.InnerHtml = RenderDbSelector(candidates, selected);

            if (selected == null)
            {
                return; // defensive; shouldn't happen since candidates.Count > 0
            }

            int top = ParseTop(Request["top"]);

            List<EventRow> events;
            List<EqStampRow> eqStamps;
            try
            {
                events = QueryEvents(selected, top);
                eqStamps = QueryEqStamps(selected, false);
            }
            catch (Exception ex)
            {
                Status.InnerHtml += string.Format("<div class='status error'>Query failed against [{0}]: {1}</div>",
                    HttpUtility.HtmlEncode(selected.Name), HttpUtility.HtmlEncode(ex.Message));
                return;
            }

            QueueStats stats;
            try
            {
                stats = QueryQueueStats(selected);
            }
            catch (Exception ex)
            {
                stats = null;
                Status.InnerHtml += string.Format("<div class='status error'>Queue overview query failed against [{0}]: {1}</div>",
                    HttpUtility.HtmlEncode(selected.Name), HttpUtility.HtmlEncode(ex.Message));
            }

            long? myStamp = GetMyStamp(eqStamps);

            Controls.InnerHtml = RenderControls(top, selected.Name);
            EqStampPanel.InnerHtml = RenderEqStampTable(eqStamps, events, selected.Name);
            EventsPanel.InnerHtml = RenderEventsTable(events, myStamp, stats);
        }

        // Finds this machine's own parsed EQSTAMP value (if any), used to draw the pointer into
        // the Events table. If more than one row somehow matches as "current machine", the first
        // one found wins - ambiguity here would itself be a sign worth noticing in the EQSTAMP
        // table, not something to silently resolve.
        private long? GetMyStamp(List<EqStampRow> eqStamps)
        {
            foreach (EqStampRow r in eqStamps)
            {
                if (r.IsCurrentMachine && r.StampValue.HasValue) return r.StampValue;
            }
            return null;
        }

        // ===================== Database discovery / connection =====================

        private string ResolveConnectionString(string dbName)
        {
            try
            {
                Database db = Factory.GetDatabase(dbName);
                if (db != null && !string.IsNullOrEmpty(db.ConnectionStringName))
                {
                    string cs = Settings.GetConnectionString(db.ConnectionStringName);
                    if (!string.IsNullOrEmpty(cs)) return cs;
                }
            }
            catch
            {
                // fall through to the direct-name fallback below
            }

            try
            {
                // Fallback: connection string name conventionally matches the database name.
                return Settings.GetConnectionString(dbName);
            }
            catch
            {
                return null;
            }
        }

        // Probes every configured database name and keeps the ones with a real, queryable
        // [EventQueue] table. Only called on a full (non-ajax) page load — this opens one
        // connection per configured database, which is fine for a manually-loaded diagnostic
        // page but too expensive to repeat on every 1s poll (see WriteSnapshotJson).
        private List<DbCandidate> DiscoverEventQueueDatabases()
        {
            List<DbCandidate> result = new List<DbCandidate>();

            foreach (string name in Factory.GetDatabaseNames())
            {
                string connStr = ResolveConnectionString(name);
                if (string.IsNullOrEmpty(connStr)) continue;

                try
                {
                    using (SqlConnection conn = new SqlConnection(connStr))
                    {
                        conn.Open();
                        using (SqlCommand cmd = new SqlCommand("SELECT TOP 1 1 FROM [EventQueue]", conn))
                        {
                            cmd.CommandTimeout = 5;
                            cmd.ExecuteScalar();
                        }
                    }
                }
                catch
                {
                    continue; // not SQL-backed, no EventQueue table, or connection failed
                }

                string dataSource = string.Empty, catalog = string.Empty;
                try
                {
                    SqlConnectionStringBuilder b = new SqlConnectionStringBuilder(connStr);
                    dataSource = b.DataSource;
                    catalog = b.InitialCatalog;
                }
                catch
                {
                    // leave blank if the connection string couldn't be parsed for display
                }

                result.Add(new DbCandidate { Name = name, ConnectionString = connStr, DataSource = dataSource, InitialCatalog = catalog });
            }

            return result;
        }

        private int ParseTop(string raw)
        {
            int top;
            if (!int.TryParse(raw, out top)) top = 50;
            if (top < 1) top = 1;
            if (top > 500) top = 500;
            return top;
        }

        // ===================== Flexible column readers =====================
        // Learned live: EventQueue's "Stamp" column is SQL Server's rowversion/timestamp type
        // (an 8-byte auto-incrementing binary counter Sitecore uses to get a free, guaranteed-
        // monotonic ordering column from SQL Server itself) — not a plain bigint. ADO.NET hands
        // that back as byte[], and Convert.ToInt64/ToString on a byte[] throws "Unable to cast
        // object of type 'System.Byte[]' to type 'System.IConvertible'". These helpers read any
        // column defensively regardless of whether it comes back as a number, string, or bytes,
        // so a schema surprise degrades gracefully instead of crashing the whole query.

        private long ReadStampValue(object value)
        {
            if (value == null || value == DBNull.Value) return 0;
            byte[] bytes = value as byte[];
            if (bytes != null) return RowVersionToInt64(bytes);
            return Convert.ToInt64(value);
        }

        // rowversion/timestamp bytes arrive in big-endian order; BitConverter needs little-endian
        // on x86/x64, so reverse before converting. Values still compare/order correctly even
        // though they're not small sequential numbers (rowversion is a per-database counter).
        private long RowVersionToInt64(byte[] bytes)
        {
            if (bytes == null || bytes.Length == 0) return 0;

            byte[] copy = (byte[])bytes.Clone();
            if (BitConverter.IsLittleEndian) Array.Reverse(copy);

            if (copy.Length < 8)
            {
                byte[] padded = new byte[8];
                Array.Copy(copy, 0, padded, 8 - copy.Length, copy.Length);
                copy = padded;
            }
            else if (copy.Length > 8)
            {
                byte[] truncated = new byte[8];
                Array.Copy(copy, copy.Length - 8, truncated, 0, 8);
                copy = truncated;
            }

            return BitConverter.ToInt64(copy, 0);
        }

        private string ReadStringValue(object value)
        {
            if (value == null || value == DBNull.Value) return string.Empty;
            byte[] bytes = value as byte[];
            if (bytes != null)
            {
                // Unexpected binary where text was expected — show a hex preview rather than crash.
                return "0x" + BitConverter.ToString(bytes).Replace("-", "");
            }
            return Convert.ToString(value);
        }

        // Parses a Properties.Value string as a stamp. Accepts a plain decimal number or a SQL
        // Server-style "0x..." hex literal (how rowversion values are often displayed as text),
        // so it lines up with whatever format the EQSTAMP value was actually written in.
        private long? ParseStampValue(string raw)
        {
            if (string.IsNullOrEmpty(raw)) return null;
            string s = raw.Trim();

            long plain;
            if (long.TryParse(s, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out plain))
            {
                return plain;
            }

            if (s.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
            {
                ulong u;
                if (ulong.TryParse(s.Substring(2), System.Globalization.NumberStyles.HexNumber, System.Globalization.CultureInfo.InvariantCulture, out u))
                {
                    return unchecked((long)u);
                }
            }

            return null;
        }

        // ===================== Queries =====================

        private List<EventRow> QueryEvents(DbCandidate db, int top)
        {
            List<EventRow> list = new List<EventRow>();
            using (SqlConnection conn = new SqlConnection(db.ConnectionString))
            {
                conn.Open();
                string sql = "SELECT TOP (@top) EventType, InstanceType, Created, Stamp, " +
                             "DATALENGTH(InstanceData) AS PayloadBytes FROM [EventQueue] ORDER BY Stamp DESC";
                using (SqlCommand cmd = new SqlCommand(sql, conn))
                {
                    cmd.CommandTimeout = 15;
                    cmd.Parameters.Add("@top", SqlDbType.Int).Value = top;
                    using (SqlDataReader reader = cmd.ExecuteReader())
                    {
                        while (reader.Read())
                        {
                            list.Add(new EventRow
                            {
                                EventType = ReadStringValue(reader["EventType"]),
                                InstanceType = ReadStringValue(reader["InstanceType"]),
                                Created = reader["Created"] is DateTime ? (DateTime)reader["Created"] : DateTime.MinValue,
                                Stamp = ReadStampValue(reader["Stamp"]),
                                PayloadBytes = reader["PayloadBytes"] == DBNull.Value ? 0 : Convert.ToInt64(reader["PayloadBytes"])
                            });
                        }
                    }
                }
            }
            return list;
        }

        // Overview independent of the top-N window: total row count, plus the single oldest row
        // (by Stamp, which correlates with insertion order). This is what actually answers "is
        // Sitecore's cleanup agent purging events before every CD has processed them" - compare
        // OldestCreated/OldestStamp against each CD's EQSTAMP in the table above.
        private QueueStats QueryQueueStats(DbCandidate db)
        {
            QueueStats stats = new QueueStats();
            using (SqlConnection conn = new SqlConnection(db.ConnectionString))
            {
                conn.Open();

                using (SqlCommand cmd = new SqlCommand("SELECT COUNT(*) FROM [EventQueue]", conn))
                {
                    // Longer timeout than the other queries here on purpose: if the cleanup agent
                    // really isn't keeping this table small, that slowness IS part of the finding,
                    // not something to hide behind a quick timeout.
                    cmd.CommandTimeout = 30;
                    object result = cmd.ExecuteScalar();
                    stats.TotalCount = (result == null || result == DBNull.Value) ? 0 : Convert.ToInt64(result);
                }

                using (SqlCommand cmd = new SqlCommand("SELECT TOP 1 Created, Stamp FROM [EventQueue] ORDER BY Stamp ASC", conn))
                {
                    cmd.CommandTimeout = 15;
                    using (SqlDataReader reader = cmd.ExecuteReader())
                    {
                        if (reader.Read())
                        {
                            stats.HasAny = true;
                            stats.OldestCreated = reader["Created"] is DateTime ? (DateTime)reader["Created"] : DateTime.MinValue;
                            stats.OldestStamp = ReadStampValue(reader["Stamp"]);
                        }
                    }
                }
            }
            return stats;
        }

        // Renders e.g. "3h 12m ago" from a (server-computed) elapsed-seconds value. Always compute
        // the elapsed time server-side (DateTime.Now - Created) rather than sending a raw timestamp
        // for the browser to diff against its own clock - browser/server clock skew would silently
        // corrupt exactly the kind of timing judgement this page exists to make.
        private string FormatAge(double totalSeconds)
        {
            if (totalSeconds < 0) totalSeconds = 0;
            TimeSpan span = TimeSpan.FromSeconds(totalSeconds);
            if (span.TotalDays >= 1) return string.Format("{0}d {1}h ago", (int)span.TotalDays, span.Hours);
            if (span.TotalHours >= 1) return string.Format("{0}h {1}m ago", (int)span.TotalHours, span.Minutes);
            if (span.TotalMinutes >= 1) return string.Format("{0}m {1}s ago", (int)span.TotalMinutes, span.Seconds);
            return string.Format("{0}s ago", (int)span.TotalSeconds);
        }

        // Broad LIKE match rather than an assumed exact prefix — Sitecore's EQSTAMP key format
        // isn't guaranteed identical across versions, and this is more robust than guessing wrong.
        // Raw keys are returned verbatim/unparsed so duplicate or subtly-mistyped keys are visible.
        private List<EqStampRow> QueryEqStamps(DbCandidate db, bool showAll)
        {
            List<EqStampRow> list = new List<EqStampRow>();
            string instanceName = Settings.InstanceName ?? string.Empty;

            using (SqlConnection conn = new SqlConnection(db.ConnectionString))
            {
                conn.Open();
                string sql = showAll
                    ? "SELECT TOP 500 [Key], [Value] FROM [Properties] ORDER BY [Key]"
                    : "SELECT TOP 500 [Key], [Value] FROM [Properties] WHERE [Key] LIKE '%EQStamp%' ORDER BY [Key]";
                using (SqlCommand cmd = new SqlCommand(sql, conn))
                {
                    cmd.CommandTimeout = 15;
                    using (SqlDataReader reader = cmd.ExecuteReader())
                    {
                        while (reader.Read())
                        {
                            string key = ReadStringValue(reader["Key"]);
                            string val = ReadStringValue(reader["Value"]);
                            list.Add(new EqStampRow
                            {
                                Key = key,
                                RawValue = val,
                                StampValue = ParseStampValue(val),
                                IsCurrentMachine = !string.IsNullOrEmpty(instanceName) &&
                                    key.IndexOf(instanceName, StringComparison.OrdinalIgnoreCase) >= 0
                            });
                        }
                    }
                }
            }
            return list;
        }

        // Refuses (server-side, in addition to the button simply not being rendered for this
        // row) to delete a Properties row that looks like it belongs to THIS machine — the
        // one self-inflicted mistake worth guarding against outright.
        private string DeleteEqStamp(DbCandidate db, string key, out bool isError)
        {
            isError = false;
            string instanceName = Settings.InstanceName ?? string.Empty;
            if (!string.IsNullOrEmpty(instanceName) && key.IndexOf(instanceName, StringComparison.OrdinalIgnoreCase) >= 0)
            {
                isError = true;
                return "Refused: that row looks like it belongs to THIS machine (" +
                    Server.HtmlEncode(instanceName) + "). Not deleting.";
            }

            try
            {
                using (SqlConnection conn = new SqlConnection(db.ConnectionString))
                {
                    conn.Open();
                    using (SqlCommand cmd = new SqlCommand("DELETE FROM [Properties] WHERE [Key] = @key", conn))
                    {
                        cmd.CommandTimeout = 15;
                        cmd.Parameters.Add("@key", SqlDbType.NVarChar, 4000).Value = key;
                        int affected = cmd.ExecuteNonQuery();
                        if (affected == 0)
                        {
                            return "No row matched key '" + Server.HtmlEncode(key) + "' (already gone?).";
                        }
                        return "Deleted Properties row '" + Server.HtmlEncode(key) + "' from [" + Server.HtmlEncode(db.Name) + "].";
                    }
                }
            }
            catch (Exception ex)
            {
                isError = true;
                return "Delete failed: " + Server.HtmlEncode(ex.Message);
            }
        }

        // ===================== Live poll endpoint =====================

        // Deliberately does NOT call DiscoverEventQueueDatabases() (which opens a connection to
        // every configured database) on every tick — that discovery only needs to happen once per
        // full page load. Here we just confirm `db` is one of Sitecore's own configured database
        // names (cheap, in-memory, no SQL) before resolving and querying it directly; if the query
        // itself fails, the error is surfaced in the JSON rather than probed for in advance.
        private void WriteSnapshotJson()
        {
            string dbName = Request.QueryString["db"];
            string[] configuredNames = Factory.GetDatabaseNames();
            bool known = false;
            foreach (string n in configuredNames)
            {
                if (string.Equals(n, dbName, StringComparison.OrdinalIgnoreCase)) { known = true; dbName = n; break; }
            }

            StringBuilder sb = new StringBuilder(16 * 1024);
            sb.Append("{");

            if (!known)
            {
                sb.Append("\"error\":\"Unknown database.\"");
            }
            else
            {
                string connStr = ResolveConnectionString(dbName);
                if (string.IsNullOrEmpty(connStr))
                {
                    sb.Append("\"error\":\"Could not resolve a connection string for '").Append(JsonEscape(dbName)).Append("'.\"");
                }
                else
                {
                    int top = ParseTop(Request.QueryString["top"]);
                    bool showAll = Request.QueryString["showAllProps"] == "1";

                    string dataSource = string.Empty, catalog = string.Empty;
                    try
                    {
                        SqlConnectionStringBuilder b = new SqlConnectionStringBuilder(connStr);
                        dataSource = b.DataSource;
                        catalog = b.InitialCatalog;
                    }
                    catch { }

                    DbCandidate cand = new DbCandidate { Name = dbName, ConnectionString = connStr, DataSource = dataSource, InitialCatalog = catalog };

                    List<EventRow> events = new List<EventRow>();
                    List<EqStampRow> eqStamps = new List<EqStampRow>();
                    string queryError = null;
                    try
                    {
                        events = QueryEvents(cand, top);
                        eqStamps = QueryEqStamps(cand, showAll);
                    }
                    catch (Exception ex)
                    {
                        queryError = ex.Message;
                    }

                    // Queried independently, with its OWN error field: a slow/failing COUNT(*) on
                    // a much-larger-than-expected table must not blank out the events/eqstamps
                    // data still being watched live (that shared "error" field aborts all rendering
                    // client-side — see poll() below — so mixing the two failure modes would hide
                    // perfectly good data just because the overview query hiccuped).
                    QueueStats stats = null;
                    string statsError = null;
                    try
                    {
                        stats = QueryQueueStats(cand);
                    }
                    catch (Exception statsEx)
                    {
                        statsError = statsEx.Message;
                    }

                    long headStamp = events.Count > 0 ? events[0].Stamp : 0;
                    long oldestVisible = events.Count > 0 ? events[events.Count - 1].Stamp : 0;
                    long? myStamp = GetMyStamp(eqStamps);

                    sb.Append("\"db\":\"").Append(JsonEscape(dbName)).Append("\"");
                    sb.Append(",\"dataSource\":\"").Append(JsonEscape(dataSource)).Append("\"");
                    sb.Append(",\"catalog\":\"").Append(JsonEscape(catalog)).Append("\"");
                    sb.Append(",\"headStamp\":").Append(headStamp);
                    sb.Append(",\"myStamp\":").Append(myStamp.HasValue ? myStamp.Value.ToString() : "null");
                    sb.Append(",\"shownCount\":").Append(events.Count);
                    sb.Append(",\"totalInQueue\":").Append(stats != null ? stats.TotalCount.ToString() : "null");
                    if (statsError != null)
                    {
                        sb.Append(",\"statsError\":\"").Append(JsonEscape(statsError)).Append("\"");
                    }
                    if (stats != null && stats.HasAny)
                    {
                        double ageSeconds = (DateTime.Now - stats.OldestCreated).TotalSeconds;
                        sb.Append(",\"oldestStamp\":").Append(stats.OldestStamp);
                        sb.Append(",\"oldestCreated\":\"").Append(JsonEscape(stats.OldestCreated.ToString("yyyy-MM-dd HH:mm:ss"))).Append("\"");
                        sb.Append(",\"oldestAgeSeconds\":").Append(ageSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture));
                    }
                    else
                    {
                        sb.Append(",\"oldestStamp\":null,\"oldestCreated\":null,\"oldestAgeSeconds\":null");
                    }
                    if (queryError != null)
                    {
                        sb.Append(",\"error\":\"").Append(JsonEscape(queryError)).Append("\"");
                    }

                    sb.Append(",\"events\":[");
                    for (int i = 0; i < events.Count; i++)
                    {
                        if (i > 0) sb.Append(',');
                        EventRow ev = events[i];
                        sb.Append("{\"stamp\":").Append(ev.Stamp);
                        sb.Append(",\"ts\":\"").Append(ev.Created.ToString("HH:mm:ss")).Append("\"");
                        sb.Append(",\"ty\":\"").Append(JsonEscape(ev.EventType)).Append("\"");
                        sb.Append(",\"it\":\"").Append(JsonEscape(ev.InstanceType)).Append("\"");
                        sb.Append(",\"pb\":").Append(ev.PayloadBytes);
                        sb.Append("}");
                    }
                    sb.Append("]");

                    sb.Append(",\"eqstamps\":[");
                    for (int i = 0; i < eqStamps.Count; i++)
                    {
                        if (i > 0) sb.Append(',');
                        EqStampRow row = eqStamps[i];
                        long newer = 0;
                        if (row.StampValue.HasValue)
                        {
                            foreach (EventRow ev in events)
                                if (ev.Stamp > row.StampValue.Value) newer++;
                        }
                        bool offscreen = row.StampValue.HasValue && events.Count > 0 && row.StampValue.Value < oldestVisible;

                        sb.Append("{\"key\":\"").Append(JsonEscape(row.Key)).Append("\"");
                        sb.Append(",\"val\":\"").Append(JsonEscape(row.RawValue)).Append("\"");
                        sb.Append(",\"stamp\":").Append(row.StampValue.HasValue ? row.StampValue.Value.ToString() : "null");
                        sb.Append(",\"mine\":").Append(row.IsCurrentMachine ? "true" : "false");
                        sb.Append(",\"newer\":").Append(newer);
                        sb.Append(",\"offscreen\":").Append(offscreen ? "true" : "false");
                        sb.Append("}");
                    }
                    sb.Append("]");
                }
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

        // Minimal JSON string escaping — same approach as CacheAdmin.aspx: escapes everything
        // above ASCII too, so the emitted JSON is pure ASCII and immune to charset mis-negotiation.
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
                        if (ch < ' ' || ch > '~')
                            sb.Append("\\u").Append(((int)ch).ToString("x4"));
                        else
                            sb.Append(ch);
                        break;
                }
            }
            return sb.ToString();
        }

        // ===================== Rendering =====================

        private string RenderDbSelector(List<DbCandidate> candidates, DbCandidate selected)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("<div class='db-panel'>");
            sb.Append("<label><b>Database:</b> <select id='db-select' onchange=\"location.href='?db='+encodeURIComponent(this.value)\">");
            foreach (DbCandidate c in candidates)
            {
                bool isSel = selected != null && string.Equals(c.Name, selected.Name, StringComparison.OrdinalIgnoreCase);
                sb.Append(string.Format("<option value=\"{0}\"{1}>{2}</option>",
                    HttpUtility.HtmlAttributeEncode(c.Name), isSel ? " selected" : "", HttpUtility.HtmlEncode(c.Name)));
            }
            sb.Append("</select></label>");

            if (selected != null)
            {
                sb.Append(string.Format(" &nbsp; <span class='conn-summary'>Data Source=<b>{0}</b>, Initial Catalog=<b>{1}</b></span>",
                    HttpUtility.HtmlEncode(selected.DataSource), HttpUtility.HtmlEncode(selected.InitialCatalog)));
            }

            sb.Append(string.Format(" &nbsp; <span class='instance-name'>This machine's InstanceName: <b>{0}</b></span>",
                HttpUtility.HtmlEncode(Settings.InstanceName ?? "(unknown)")));

            sb.Append("</div>");
            return sb.ToString();
        }

        private string RenderControls(int top, string selectedDbName)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("<div class='controls-panel'>");
            sb.Append("<button type='button' id='btn-pause' onclick='togglePause()'>Pause</button>");
            sb.Append("&nbsp;&nbsp;Interval (s): <input type='number' id='interval-input' min='1' value='1' style='width:50px'>");
            sb.Append("&nbsp;&nbsp;Show top: <input type='number' id='top-input' min='1' max='500' value='" + top + "' style='width:60px'>");
            sb.Append("&nbsp;&nbsp;<label><input type='checkbox' id='cb-show-all-props'> Show all Properties rows (debug)</label>");
            sb.Append("&nbsp;&nbsp;<span id='poll-status' class='poll-status'>starting...</span>");
            // Single hidden field, reused both by JS (reads .value to build the poll URL) and by
            // the form POST (so Delete round-trips against the currently viewed database). Do NOT
            // add a second field named 'db' anywhere else in this form.
            sb.Append("<input type='hidden' id='hidden-db' name='db' value=\"" +
                HttpUtility.HtmlAttributeEncode(selectedDbName ?? string.Empty) + "\">");
            sb.Append("</div>");
            return sb.ToString();
        }

        private string RenderEqStampTable(List<EqStampRow> rows, List<EventRow> events, string dbName)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("<div class='eqstamp-head'>EQSTAMP rows (Properties table, key LIKE '%EQStamp%') &mdash; ");
            sb.Append("raw keys shown verbatim so duplicate/mistyped keys across machines are visible. ");
            sb.Append("<b>&#9654;</b> marks this machine's own row. Delete only appears once a row is more than ");
            sb.Append(EqStampStaleThreshold.ToString("#,0"));
            sb.Append(" behind the current head stamp (or its value isn't a valid stamp at all).</div>");
            sb.Append("<table id='eqstamp-table'><thead><tr>");
            sb.Append("<th>Key</th><th>Stamp</th><th>Newer events (visible window)</th><th>Actions</th>");
            sb.Append("</tr></thead><tbody id='eqstamp-tbody'>");
            sb.Append(RenderEqStampRows(rows, events));
            sb.Append("</tbody></table>");
            return sb.ToString();
        }

        private string RenderEqStampRows(List<EqStampRow> rows, List<EventRow> events)
        {
            StringBuilder sb = new StringBuilder();
            long oldestVisible = events.Count > 0 ? events[events.Count - 1].Stamp : 0;
            long headStamp = events.Count > 0 ? events[0].Stamp : 0;
            bool haveHeadStamp = events.Count > 0;

            foreach (EqStampRow row in rows)
            {
                long newer = 0;
                if (row.StampValue.HasValue)
                {
                    foreach (EventRow ev in events)
                        if (ev.Stamp > row.StampValue.Value) newer++;
                }
                bool offscreen = row.StampValue.HasValue && events.Count > 0 && row.StampValue.Value < oldestVisible;

                sb.Append("<tr class='" + (row.IsCurrentMachine ? "eq-mine" : "") + "' data-key=\"" +
                    HttpUtility.HtmlAttributeEncode(row.Key) + "\">");

                sb.Append("<td>" + (row.IsCurrentMachine ? "<b>&#9654; " : "") +
                    HttpUtility.HtmlEncode(row.Key) + (row.IsCurrentMachine ? "</b>" : "") + "</td>");

                // Stamp: a formatted number when parseable (values are ~9 digits, hence the
                // thousands grouping), or the raw text in quotes to flag it wasn't valid.
                if (row.StampValue.HasValue)
                {
                    sb.Append("<td class='AlignRight'>" + row.StampValue.Value.ToString("#,0") + "</td>");
                }
                else
                {
                    sb.Append("<td>&quot;" + HttpUtility.HtmlEncode(row.RawValue) + "&quot;</td>");
                }

                sb.Append("<td class='AlignRight'>" + (row.StampValue.HasValue
                    ? (offscreen ? "&gt;=" + newer + " (older than visible window)" : newer.ToString())
                    : "n/a") + "</td>");

                sb.Append("<td>");
                if (CanOfferDelete(row, headStamp, haveHeadStamp))
                {
                    sb.Append("<button type='submit' name='deleteKey' value=\"" + HttpUtility.HtmlAttributeEncode(row.Key) + "\" " +
                        "onclick=\"return confirm('This row looks stale (more than " + EqStampStaleThreshold + " behind, or not a valid " +
                        "stamp). Delete it? Double-check the instance is really retired first " +
                        "\\u2014 if it comes back, deleting its bookmark can make it reprocess or skip a backlog.');\">Delete</button>");
                }
                else if (row.IsCurrentMachine)
                {
                    sb.Append("<i>(this machine)</i>");
                }
                else
                {
                    sb.Append("<i>(active)</i>");
                }
                sb.Append("</td>");
                sb.Append("</tr>");
            }
            return sb.ToString();
        }

        private string RenderEventsTable(List<EventRow> events, long? myStamp, QueueStats stats)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("<div class='events-head'>EventQueue (top " + events.Count + " by Stamp, newest first) &mdash; " +
                "metadata only; the InstanceData payload is not decoded. ");
            sb.Append("<b>&#9654;</b> marks the event this machine's own EQSTAMP currently points to, when it's within this visible window.</div>");
            sb.Append("<table id='events-table'><thead><tr><th>Stamp</th><th>Created</th><th>EventType</th><th>InstanceType</th><th>Payload</th></tr></thead>");
            sb.Append("<tbody id='events-tbody'>");
            sb.Append(RenderEventRows(events, myStamp));
            sb.Append("</tbody></table>");
            sb.Append(RenderQueueFooter(events.Count, stats));
            return sb.ToString();
        }

        // Shown right after the table ("at the end of the queue"): total row count regardless of
        // the top-N window, and the single oldest row in the whole table. This is the direct check
        // for "is the cleanup agent purging events before every CD has processed them" - compare
        // OldestCreated/OldestStamp here against the EQSTAMP table above.
        private string RenderQueueFooter(int shownCount, QueueStats stats)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("<div id='events-footer' class='events-footer'>");

            if (stats == null)
            {
                sb.Append("Queue overview unavailable (see error above).");
                sb.Append("</div>");
                return sb.ToString();
            }

            long more = stats.TotalCount - shownCount;
            if (more < 0) more = 0;

            sb.Append("Total events in queue: <b>" + stats.TotalCount.ToString("#,0") + "</b>");
            if (more > 0)
            {
                sb.Append(" (<b>" + more.ToString("#,0") + "</b> more not shown above)");
            }
            sb.Append(". ");

            if (stats.HasAny)
            {
                double ageSeconds = (DateTime.Now - stats.OldestCreated).TotalSeconds;
                sb.Append("Oldest event in queue: <b>" + stats.OldestCreated.ToString("yyyy-MM-dd HH:mm:ss") + "</b> (" +
                    FormatAge(ageSeconds) + ", stamp " + stats.OldestStamp.ToString("#,0") + "). ");
                sb.Append("If a CD's EQSTAMP is older than this, the events it still needs may already have been purged by Sitecore's cleanup agent.");
            }
            else
            {
                sb.Append("Queue is currently empty.");
            }

            sb.Append("</div>");
            return sb.ToString();
        }

        private string RenderEventRows(List<EventRow> events, long? myStamp)
        {
            StringBuilder sb = new StringBuilder();
            foreach (EventRow ev in events)
            {
                bool isMine = myStamp.HasValue && ev.Stamp == myStamp.Value;

                sb.Append("<tr class='" + (isMine ? "eq-mine" : "") + "' data-stamp='" + ev.Stamp + "'>");
                sb.Append("<td class='AlignRight'>" + (isMine ? "<b>&#9654; " : "") +
                    ev.Stamp.ToString("#,0") + (isMine ? "</b>" : "") + "</td>");
                sb.Append("<td>" + ev.Created.ToString("HH:mm:ss") + "</td>");
                sb.Append("<td class='" + EventTypeCssClass(ev.EventType) + "'>" + HttpUtility.HtmlEncode(ShortTypeName(ev.EventType)) + "</td>");
                sb.Append("<td class='instance-type'>" + HttpUtility.HtmlEncode(ShortTypeName(ev.InstanceType)) + "</td>");
                sb.Append("<td class='AlignRight'>" + FormatBytes(ev.PayloadBytes) + "</td>");
                sb.Append("</tr>");
            }
            return sb.ToString();
        }

        private string ShortTypeName(string fullyQualified)
        {
            if (string.IsNullOrEmpty(fullyQualified)) return string.Empty;
            int comma = fullyQualified.IndexOf(',');
            return comma > 0 ? fullyQualified.Substring(0, comma) : fullyQualified;
        }

        private string EventTypeCssClass(string eventType)
        {
            string t = eventType ?? string.Empty;
            if (t.IndexOf("PublishEnd", StringComparison.OrdinalIgnoreCase) >= 0) return "ev-publish";
            if (t.IndexOf("Deleted", StringComparison.OrdinalIgnoreCase) >= 0 ||
                t.IndexOf("RemovedVersion", StringComparison.OrdinalIgnoreCase) >= 0) return "ev-deleted";
            if (t.IndexOf("Saved", StringComparison.OrdinalIgnoreCase) >= 0 ||
                t.IndexOf("AddedVersion", StringComparison.OrdinalIgnoreCase) >= 0) return "ev-saved";
            return "ev-other";
        }

        private string FormatBytes(long bytes)
        {
            if (bytes < 1024) return bytes + " B";
            if (bytes < 1048576) return ((double)bytes / 1024.0).ToString("#,0.#") + " KB";
            return ((double)bytes / 1048576.0).ToString("#,0.#") + " MB";
        }
    </script>
</head>
<body>
    <form method="post">
        <div id="Header" runat="server">
        </div>
        <div id="Status" runat="server">
        </div>
        <div id="DbInfo" runat="server">
        </div>
        <div id="Controls" runat="server">
        </div>
        <div id="EqStampPanel" runat="server">
        </div>
        <div id="EventsPanel" runat="server">
        </div>
    </form>

    <script>
        // ================= EventQueue live polling (client) =================
        // Unlike CacheAdmin.aspx's opt-in tracking, this page auto-starts polling: its whole
        // purpose is watching events arrive in real time during a test publish. No server-side
        // state is needed at all (Stamp only ever increases; every poll just re-queries fresh).
        (function () {
            var paused = false;
            var timer = null;
            var inFlight = false;
            var pollCount = 0;
            var highestStampSeen = 0;

            var LS_INTERVAL = "eventQueue-interval";

            function q(id) { return document.getElementById(id); }

            function setStatus(msg) {
                var el = q("poll-status");
                if (el) { el.textContent = msg; }
            }

            function td(text, cls) {
                var el = document.createElement("td");
                if (cls) { el.className = cls; }
                el.textContent = text;
                return el;
            }

            function shortType(t) {
                if (!t) { return ""; }
                var i = t.indexOf(",");
                return i > 0 ? t.substring(0, i) : t;
            }

            function eventTypeClass(t) {
                var tl = (t || "").toLowerCase();
                if (tl.indexOf("publishend") !== -1) { return "ev-publish"; }
                if (tl.indexOf("deleted") !== -1 || tl.indexOf("removedversion") !== -1) { return "ev-deleted"; }
                if (tl.indexOf("saved") !== -1 || tl.indexOf("addedversion") !== -1) { return "ev-saved"; }
                return "ev-other";
            }

            function formatBytes(n) {
                if (n < 1024) { return n + " B"; }
                if (n < 1048576) { return (n / 1024).toFixed(1) + " KB"; }
                return (n / 1048576).toFixed(1) + " MB";
            }

            // Thousands-grouped integer formatting (stamps are ~9 digits) — hand-rolled rather
            // than toLocaleString() so the grouping is deterministic regardless of browser locale.
            function formatNumber(n) {
                var s = String(n);
                var neg = s.charAt(0) === "-";
                if (neg) { s = s.substring(1); }
                var parts = [];
                while (s.length > 3) {
                    parts.unshift(s.slice(-3));
                    s = s.slice(0, -3);
                }
                parts.unshift(s);
                return (neg ? "-" : "") + parts.join(",");
            }

            // Mirrors FormatAge in the server-rendered path. Takes a server-computed elapsed-
            // seconds value rather than diffing against the browser's own clock - relying on the
            // browser's clock here would silently corrupt exactly the kind of timing judgement
            // this page exists to make.
            function formatAge(totalSeconds) {
                if (totalSeconds === null || totalSeconds === undefined) { return ""; }
                if (totalSeconds < 0) { totalSeconds = 0; }
                var days = Math.floor(totalSeconds / 86400);
                var hours = Math.floor((totalSeconds % 86400) / 3600);
                var minutes = Math.floor((totalSeconds % 3600) / 60);
                var seconds = Math.floor(totalSeconds % 60);
                if (days >= 1) { return days + "d " + hours + "h ago"; }
                if (hours >= 1) { return hours + "h " + minutes + "m ago"; }
                if (minutes >= 1) { return minutes + "m " + seconds + "s ago"; }
                return seconds + "s ago";
            }

            function renderQueueFooter(data) {
                var el = q("events-footer");
                if (!el) { return; }
                el.innerHTML = "";

                if (data.totalInQueue === null || data.totalInQueue === undefined) {
                    el.textContent = "Queue overview unavailable" + (data.statsError ? (": " + data.statsError) : ".");
                    return;
                }

                var more = data.totalInQueue - (data.shownCount || 0);
                if (more < 0) { more = 0; }

                el.appendChild(document.createTextNode("Total events in queue: "));
                var totalB = document.createElement("b");
                totalB.textContent = formatNumber(data.totalInQueue);
                el.appendChild(totalB);

                if (more > 0) {
                    el.appendChild(document.createTextNode(" ("));
                    var moreB = document.createElement("b");
                    moreB.textContent = formatNumber(more);
                    el.appendChild(moreB);
                    el.appendChild(document.createTextNode(" more not shown above)"));
                }
                el.appendChild(document.createTextNode(". "));

                if (data.oldestCreated) {
                    el.appendChild(document.createTextNode("Oldest event in queue: "));
                    var oldB = document.createElement("b");
                    oldB.textContent = data.oldestCreated;
                    el.appendChild(oldB);
                    el.appendChild(document.createTextNode(" (" + formatAge(data.oldestAgeSeconds) + ", stamp " +
                        formatNumber(data.oldestStamp) + "). If a CD's EQSTAMP is older than this, the events it still " +
                        "needs may already have been purged by Sitecore's cleanup agent."));
                } else {
                    el.appendChild(document.createTextNode("Queue is currently empty."));
                }
            }

            // Mirrors CanOfferDelete in the server-rendered path (EventQueue.aspx C#) — keep the
            // two in sync. STALE_THRESHOLD must match EqStampStaleThreshold server-side.
            var STALE_THRESHOLD = 100;

            function canOfferDelete(r, headStamp, haveHead) {
                if (r.mine) { return false; }
                // "Show all Properties rows" can list totally unrelated Sitecore properties —
                // never offer Delete for a key that doesn't actually look like an EQSTAMP entry.
                if (r.key.toLowerCase().indexOf("eqstamp") === -1) { return false; }
                if (r.stamp === null) { return true; }
                if (!haveHead) { return false; }
                return (headStamp - r.stamp) > STALE_THRESHOLD;
            }

            // Pointer glyph for "this machine" — built from a decimal code point (pure-ASCII
            // source) so it renders correctly regardless of charset, per this folder's convention.
            var GLYPH_PTR = String.fromCharCode(9654); // U+25B6 black right-pointing triangle

            function seedHighestStamp() {
                var rows = document.querySelectorAll("#events-tbody tr[data-stamp]");
                var max = 0;
                for (var i = 0; i < rows.length; i++) {
                    var s = parseInt(rows[i].getAttribute("data-stamp"), 10);
                    if (!isNaN(s) && s > max) { max = s; }
                }
                return max;
            }

            function renderEvents(events, myStamp) {
                var tbody = q("events-tbody");
                if (!tbody) { return; }
                tbody.innerHTML = "";

                var newHighest = highestStampSeen;
                var newRows = [];

                for (var i = 0; i < events.length; i++) {
                    var ev = events[i];
                    var isNew = ev.stamp > highestStampSeen;
                    if (ev.stamp > newHighest) { newHighest = ev.stamp; }
                    var isMine = (myStamp !== null && myStamp !== undefined && ev.stamp === myStamp);

                    var tr = document.createElement("tr");
                    tr.setAttribute("data-stamp", ev.stamp);
                    if (isMine) { tr.classList.add("eq-mine"); }

                    var stampTd = document.createElement("td");
                    stampTd.className = "AlignRight";
                    if (isMine) {
                        var b = document.createElement("b");
                        b.textContent = GLYPH_PTR + " " + formatNumber(ev.stamp);
                        stampTd.appendChild(b);
                    } else {
                        stampTd.textContent = formatNumber(ev.stamp);
                    }
                    tr.appendChild(stampTd);

                    tr.appendChild(td(ev.ts, ""));
                    tr.appendChild(td(shortType(ev.ty), eventTypeClass(ev.ty)));
                    tr.appendChild(td(shortType(ev.it), "instance-type"));
                    tr.appendChild(td(formatBytes(ev.pb), "AlignRight"));

                    if (isNew) { tr.classList.add("flash-new"); newRows.push(tr); }
                    tbody.appendChild(tr);
                }
                highestStampSeen = newHighest;

                if (newRows.length) {
                    setTimeout(function () {
                        for (var j = 0; j < newRows.length; j++) { newRows[j].classList.remove("flash-new"); }
                    }, 1500);
                }
            }

            function renderEqStamps(rows, headStamp, haveHead) {
                var tbody = q("eqstamp-tbody");
                if (!tbody) { return; }
                tbody.innerHTML = "";

                for (var i = 0; i < rows.length; i++) {
                    var r = rows[i];
                    var tr = document.createElement("tr");
                    if (r.mine) { tr.className = "eq-mine"; }
                    tr.setAttribute("data-key", r.key);

                    var keyTd = document.createElement("td");
                    if (r.mine) {
                        var b = document.createElement("b");
                        b.textContent = GLYPH_PTR + " " + r.key;
                        keyTd.appendChild(b);
                    } else {
                        keyTd.textContent = r.key;
                    }
                    tr.appendChild(keyTd);

                    // Stamp: formatted number when parseable, or the raw text in quotes to flag
                    // it wasn't valid — merges what used to be two separate columns.
                    if (r.stamp === null) {
                        tr.appendChild(td("\"" + r.val + "\"", ""));
                    } else {
                        tr.appendChild(td(formatNumber(r.stamp), "AlignRight"));
                    }

                    tr.appendChild(td(
                        r.stamp === null ? "n/a" : (r.offscreen ? (">=" + r.newer + " (older than visible window)") : String(r.newer)),
                        "AlignRight"));

                    var actionTd = document.createElement("td");
                    if (canOfferDelete(r, headStamp, haveHead)) {
                        var btn = document.createElement("button");
                        btn.type = "submit";
                        btn.name = "deleteKey";
                        btn.value = r.key;
                        btn.textContent = "Delete";
                        btn.onclick = function () {
                            return confirm("This row looks stale (more than " + STALE_THRESHOLD + " behind, or not a valid stamp). " +
                                "Delete it? Double-check the instance is really retired first " +
                                "- if it comes back, deleting its bookmark can make it reprocess or skip a backlog.");
                        };
                        actionTd.appendChild(btn);
                    } else if (r.mine) {
                        actionTd.textContent = "(this machine)";
                    } else {
                        actionTd.textContent = "(active)";
                    }
                    tr.appendChild(actionTd);

                    tbody.appendChild(tr);
                }
            }

            function poll() {
                if (paused || inFlight) { return; }

                var dbEl = q("hidden-db");
                if (!dbEl) { return; } // no database available; nothing to poll

                inFlight = true;

                var topEl = q("top-input");
                var top = (topEl && topEl.value) ? topEl.value : "50";
                var showAllEl = q("cb-show-all-props");
                var showAll = (showAllEl && showAllEl.checked) ? "1" : "0";

                fetch("?ajax=snapshot&db=" + encodeURIComponent(dbEl.value) +
                      "&top=" + encodeURIComponent(top) + "&showAllProps=" + showAll,
                      { cache: "no-store" })
                    .then(function (r) {
                        if (!r.ok) { throw new Error("HTTP " + r.status); }
                        return r.json();
                    })
                    .then(function (data) {
                        pollCount++;
                        if (data.error) {
                            setStatus("Error: " + data.error);
                        } else {
                            renderEvents(data.events || [], data.myStamp);
                            renderEqStamps(data.eqstamps || [], data.headStamp, (data.events || []).length > 0);
                            renderQueueFooter(data);
                            var statusMsg = "polls: " + pollCount + ", head stamp: " + formatNumber(data.headStamp) + ", db: " + data.db;
                            if (data.statsError) { statusMsg += " (queue overview error: " + data.statsError + ")"; }
                            setStatus(statusMsg);
                        }
                    })
                    .catch(function (e) {
                        setStatus("Poll error: " + e.message + " (still trying)");
                    })
                    .then(function () { inFlight = false; });
            }

            function startTimer() {
                var ivEl = q("interval-input");
                if (!ivEl) { return; }
                var iv = parseInt(ivEl.value, 10) || 1;
                if (timer) { clearInterval(timer); }
                timer = setInterval(poll, iv * 1000);
            }

            window.togglePause = function () {
                paused = !paused;
                var btn = q("btn-pause");
                if (paused) {
                    btn.textContent = "Resume";
                    if (timer) { clearInterval(timer); timer = null; }
                    setStatus("Paused.");
                } else {
                    btn.textContent = "Pause";
                    poll();
                    startTimer();
                }
            };

            document.addEventListener("DOMContentLoaded", function () {
                highestStampSeen = seedHighestStamp();

                var ivEl = q("interval-input");
                var savedIv = localStorage.getItem(LS_INTERVAL);
                if (savedIv && ivEl) { ivEl.value = savedIv; }

                if (ivEl) {
                    ivEl.addEventListener("change", function () {
                        localStorage.setItem(LS_INTERVAL, this.value);
                        if (!paused) { startTimer(); }
                    });
                    // Don't let Enter in a text field implicitly submit the form.
                    ivEl.addEventListener("keydown", function (e) { if (e.key === "Enter") { e.preventDefault(); } });
                }

                var topEl = q("top-input");
                if (topEl) {
                    topEl.addEventListener("change", function () { if (!paused) { poll(); } });
                    topEl.addEventListener("keydown", function (e) { if (e.key === "Enter") { e.preventDefault(); } });
                }

                var showAllEl = q("cb-show-all-props");
                if (showAllEl) {
                    showAllEl.addEventListener("change", function () { if (!paused) { poll(); } });
                }

                // Auto-start — this page exists specifically to watch events arrive live.
                poll();
                startTimer();
            });
        })();
    </script>
</body>
</html>

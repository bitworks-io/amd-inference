using System;
using System.Collections.Generic;
using System.Diagnostics.Eventing.Reader;
using System.Text;

namespace FastLlmTests
{
    // A live subscription to one Windows event log. It keeps the record id of EVERY event delivered (so a gap can be found) and, for event 4103
    // of one process, the rendered text at the moment it arrives - so the size of the log, and a circular log overwriting its oldest records,
    // cannot take anything out of what was captured. Windows only; the suites never compile it elsewhere.
    public sealed class ModuleLogTap : IDisposable
    {
        private readonly object gate = new object();
        private readonly EventLogWatcher watcher;
        private readonly int processId;
        private readonly List<long> ids = new List<long>();
        private readonly List<long> textIds = new List<long>();
        private readonly List<string> texts = new List<string>();
        private int errors;
        private string firstErrorType;

        public ModuleLogTap(string logName, int processId)
        {
            this.processId = processId;
            watcher = new EventLogWatcher(new EventLogQuery(logName, PathType.LogName, "*"));
            watcher.EventRecordWritten += OnWritten;
            watcher.Enabled = true;
        }

        private void OnWritten(object sender, EventRecordWrittenEventArgs e)
        {
            EventRecord record = e.EventRecord;
            try
            {
                lock (gate)
                {
                    if (e.EventException != null)
                    {
                        errors++;
                        if (firstErrorType == null) { firstErrorType = e.EventException.GetType().Name; }
                        return;
                    }
                    if (record == null) { return; }
                    long id = record.RecordId.HasValue ? record.RecordId.Value : -1;
                    ids.Add(id);
                    if (record.Id == 4103 && record.ProcessId.HasValue && record.ProcessId.Value == processId)
                    {
                        string text = null;
                        try { text = record.FormatDescription(); } catch (EventLogException) { text = null; }
                        if (text == null)
                        {
                            StringBuilder joined = new StringBuilder();
                            foreach (EventProperty property in record.Properties)
                            {
                                if (joined.Length > 0) { joined.Append('\n'); }
                                joined.Append(property.Value == null ? "" : property.Value.ToString());
                            }
                            text = joined.ToString();
                        }
                        textIds.Add(id);
                        texts.Add(text);
                    }
                }
            }
            finally
            {
                if (record != null) { record.Dispose(); }
            }
        }

        public string Text()
        {
            lock (gate) { return string.Join("\n", texts); }
        }

        public long FindRecord(string needle)
        {
            lock (gate)
            {
                for (int i = 0; i < texts.Count; i++)
                {
                    if (texts[i].IndexOf(needle, StringComparison.Ordinal) >= 0) { return textIds[i]; }
                }
            }
            return -1;
        }

        public long[] RecordIds()
        {
            lock (gate) { return ids.ToArray(); }
        }

        // How many record ids from first to last (both included) were never delivered.
        public long MissingBetween(long first, long last)
        {
            if (first < 0 || last < first) { return -1; }
            lock (gate)
            {
                HashSet<long> seen = new HashSet<long>(ids);
                long missing = 0;
                for (long id = first; id <= last; id++) { if (!seen.Contains(id)) { missing++; } }
                return missing;
            }
        }

        public int Errors { get { lock (gate) { return errors; } } }

        public string FirstErrorType { get { lock (gate) { return firstErrorType == null ? "" : firstErrorType; } } }

        public void Dispose()
        {
            watcher.Enabled = false;
            watcher.EventRecordWritten -= OnWritten;
            watcher.Dispose();
        }
    }
}

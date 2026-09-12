//+------------------------------------------------------------------+
//| TradeJournalEA.mq5 (server build)                                 |
//| Auto-journals every deal (manual or automated) into an           |
//| append-only, hash-chained JSONL file under MQL5\Files\journal\ - |
//| identical to the local-only build. Additionally, if               |
//| InpServerUrl/InpApiToken are set, best-effort mirrors each deal   |
//| and the live balance/equity state to the hosted TAPE server over  |
//| HTTPS/HTTP (see PushToServer) - the local file stays              |
//| authoritative either way, this is purely an additional push,     |
//| never a replacement.                                              |
//+------------------------------------------------------------------+
#property strict
#property copyright "TAPE - local hash-chained journal, optional server push"
#property version   "1.21"

#include <TradeJournal\Hashing.mqh>

#define GENESIS_HASH "0000000000000000000000000000000000000000000000000000000000000000"
// Sent with every live-state push (see WriteLiveState) so the dashboard can
// tell a trader whose EA is still on an older build to redownload - bump
// this (and #property version above) whenever this file changes, and
// LATEST_EA_VERSION in app/rules_engine.py to match.
#define EA_VERSION "1.13"

#define RECONCILE_CHECK_SECONDS 300 // how often OnTimer re-checks the server has everything (see ReconcileServerPushes)
datetime g_lastReconcileTime = 0;

input string InpServerUrl = "";  // Server URL (blank = local-only, no push)
input string InpApiToken  = "";  // Your TAPE account's API token (Settings -> Connect EA)

// 2026-09-11 third security audit: InpServerUrl used to be sent over
// whatever scheme the trader typed, including a plain "http://" -
// WebRequest would then send X-Api-Token in cleartext, and anyone on the
// same network path could read it. Checked once at OnInit and cached
// here rather than re-parsing the string on every single push.
bool g_serverUrlIsHttps = true;

string g_currentFile      = "";
string g_prevHash         = "";
string g_lastProcessedKey = ""; // "<ticket>_<entry>" of the last line actually written

string g_eventsFile     = "";
string g_eventsPrevHash = "";

// Last known SL/TP per open position ticket, so a TRADE_TRANSACTION_POSITION
// firing can be turned into "SL changed" / "TP changed" instead of a bare
// snapshot. Parallel arrays, not a struct array, since MQL5 has no map type.
long   g_evPosTicket[];
double g_evPosSl[];
double g_evPosTp[];

#define RR_ALERT_THRESHOLD 3.0
#define RR_CHECK_SECONDS   5
#define RR_PERCENT_PER_R   1.0   // 1R = this % of current account balance

//+------------------------------------------------------------------+
int OnInit()
  {
   FolderCreate("journal");
   if(InpServerUrl != "" && StringFind(InpServerUrl, "https://") != 0)
     {
      g_serverUrlIsHttps = false;
      // Print() alone (the EA's usual way of reporting problems) lands in
      // the Experts log tab almost nobody checks - this specific case
      // can never self-report through the dashboard either (the whole
      // point of the fix is that NOTHING gets sent to the server while
      // misconfigured, so the server has no way to know and show its
      // own warning). Alert() pops a modal the trader can't miss once;
      // Comment() leaves a lasting reminder directly on the chart in
      // case the popup gets dismissed without being read.
      Print("TradeJournalEA: Server URL does not start with https:// - server push "
            "DISABLED to avoid sending your API token in plaintext. Fix the Server URL "
            "input (use https://) and re-attach the EA to re-enable it.");
      Alert("TradeJournalEA: Server URL must start with https:// - server sync is OFF "
            "until this is fixed (your local journal keeps recording normally).");
      Comment("TradeJournalEA: server sync OFF - Server URL must start with https://");
     }
   LoadChainForCurrentMonth();
   LoadEventsChainForCurrentMonth();
   BackfillMissedDeals();
   ReconcileServerPushes();
   ReconcileMissingBars();
   EventSetTimer(RR_CHECK_SECONDS);
   Print("TradeJournalEA initialized. Journal file: ", g_currentFile, " Events file: ", g_eventsFile);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   WriteLiveState();
   CheckOpenPositionsForRR();

   if((long)(TimeCurrent() - g_lastReconcileTime) >= RECONCILE_CHECK_SECONDS)
     {
      g_lastReconcileTime = TimeCurrent();
      ReconcileServerPushes();
      ReconcileMissingBars();
     }
  }

// Overwrites (not appends) a small snapshot of current balance/equity so
// the dashboard can fold open positions' floating P&L into the daily risk
// limit in near-real-time, instead of only seeing it once a position
// closes. Plain state file, not part of the tamper-evident trade record -
// same reasoning as rr_alerts.jsonl. Also lists each open position's own
// live P&L (not just the account-wide total) so the dashboard/PiP widget
// can show which position is winning or losing right now.
void WriteLiveState()
  {
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   int    openCount = PositionsTotal();

   string openJson = "";
   for(int i = 0; i < openCount; i++)
     {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == 0 || !PositionSelectByTicket(posTicket))
         continue;

      long   posId  = PositionGetInteger(POSITION_IDENTIFIER);
      string symbol = PositionGetString(POSITION_SYMBOL);
      string side   = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "buy" : "sell";
      double volume = PositionGetDouble(POSITION_VOLUME);
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      if(openJson != "")
         openJson += ",";
      openJson += StringFormat(
         "{\"position_id\":%I64d,\"symbol\":\"%s\",\"side\":\"%s\",\"volume\":%.2f,\"profit\":%.2f}",
         posId, JsonEscape(symbol), side, volume, profit);
     }

   long accountId = AccountInfoInteger(ACCOUNT_LOGIN);
   string line = StringFormat(
      "{\"account_id\":%I64d,\"balance\":%.2f,\"equity\":%.2f,\"open_positions\":%d,\"open\":[%s],\"ea_version\":\"%s\"}",
      accountId, balance, equity, openCount, openJson, EA_VERSION);

   int handle = FileOpen("journal\\live_state.json", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE)
     {
      Print("TradeJournalEA: could not write live_state.json, err=", GetLastError());
      return;
     }
   FileWriteString(handle, line);
   FileClose(handle);

   PushToServer("/api/ingest/live-state", line);
  }

//+------------------------------------------------------------------+
// Best-effort HTTP push to the hosted server (see Крок 0 - the EA
// pushes directly, no separate always-on local relay process needed).
// Never blocks or breaks the EA's own local journaling if it fails
// (network down, server unreachable, wrong/missing token, etc.) - the
// local hash-chained file, already written by the time this is called,
// remains the sole authoritative record either way; this is purely a
// best-effort mirror so the hosted dashboard has the same data. Silently
// no-ops if InpServerUrl/InpApiToken aren't set - local-only mode stays
// exactly as it always was. Requires the server's URL to be added to
// MT5's allowed WebRequest list first (Tools -> Options -> Expert
// Advisors -> "Allow WebRequest for listed URL") - MT5 blocks all
// outbound WebRequest calls to unlisted URLs by design, err 4060 below.
//+------------------------------------------------------------------+
void PushToServer(const string endpoint, const string jsonBody)
  {
   if(InpServerUrl == "" || InpApiToken == "" || !g_serverUrlIsHttps)
      return;

   string url     = InpServerUrl + endpoint;
   string headers = "Content-Type: application/json\r\nX-Api-Token: " + InpApiToken + "\r\n";

   char postData[];
   int  len = StringToCharArray(jsonBody, postData, 0, WHOLE_ARRAY, CP_UTF8) - 1; // drop StringToCharArray's trailing null - it would otherwise land in the POST body as a stray byte
   ArrayResize(postData, len);

   char   result[];
   string resultHeaders;
   ResetLastError();
   int status = WebRequest("POST", url, headers, 5000, postData, result, resultHeaders);

   if(status == -1)
     {
      int err = GetLastError();
      if(err == 4060)
         Print("TradeJournalEA: server push blocked - add ", InpServerUrl,
               " under Tools > Options > Expert Advisors > \"Allow WebRequest for listed URL\"");
      else
         Print("TradeJournalEA: server push to ", endpoint, " failed, err=", err);
     }
   else if(status != 200)
     {
      Print("TradeJournalEA: server push to ", endpoint, " returned HTTP ", status);
     }
  }

//+------------------------------------------------------------------+
// Walks every currently open position (any symbol, not just this chart's
// own - PositionGetTicket()/SymbolInfoDouble() work across symbols, unlike
// OnTick() which only fires for the chart's own symbol) and appends a
// line to journal\rr_alerts.jsonl the first time one reaches 3R. This is
// a plain, non-hash-chained JSONL stream on purpose - it's a transient
// "go look at this" signal for the dashboard to relay as a desktop toast,
// not part of the permanent tamper-evident trade record.
//+------------------------------------------------------------------+
// The dashboard writes journal\account_config.json (roughly once a
// minute, from its own real starting-balance detection - the same
// number Compliance/Phase Profit Target use) so 1R is 1% of the STABLE
// starting balance, not live fluctuating AccountInfoDouble(ACCOUNT_BALANCE)
// - otherwise the same $ profit would read as a different R-multiple
// every time realized balance moves. Falls back to live balance if the
// file doesn't exist yet (dashboard never started) or is unparseable.
double ReadStartBalance()
  {
   string line = ReadLastLine("journal\\account_config.json");
   if(line != "")
     {
      int idx = StringFind(line, "\"start_balance\":");
      if(idx >= 0)
        {
         int start = idx + StringLen("\"start_balance\":");
         int end   = StringFind(line, "}", start);
         if(end > start)
           {
            double val = StringToDouble(StringSubstr(line, start, end - start));
            if(val > 0.0)
               return val;
           }
        }
     }
   return AccountInfoDouble(ACCOUNT_BALANCE);
  }

void CheckOpenPositionsForRR()
  {
   double balance = ReadStartBalance();
   double riskDollar = balance * (RR_PERCENT_PER_R / 100.0); // 1R in account currency
   if(riskDollar <= 0.0)
      return;

   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == 0 || !PositionSelectByTicket(posTicket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double rMultiple = profit / riskDollar;
      long ticket = (long)posTicket;

      // Re-fires every RR_CHECK_SECONDS while rMultiple stays >= threshold,
      // rather than once per position - the user wants a live reminder as
      // long as an open position sits above 3R, not a single ping. Windows
      // Toast naturally throttles the visible banners since every 3R toast
      // shares the same (tag, group), so this reads as "the notification
      // periodically refreshes with the latest R/profit" rather than actual
      // spam - see check_rr_alerts()'s per-check batching and the file
      // truncation that keeps rr_alerts.jsonl from growing unbounded.
      if(rMultiple >= RR_ALERT_THRESHOLD)
        {
         WriteRREvent(ticket, symbol, rMultiple, profit);
        }
     }
  }

void WriteRREvent(const long positionId, const string symbol, const double rMultiple, const double profit)
  {
   long accountId = AccountInfoInteger(ACCOUNT_LOGIN);
   string line = StringFormat(
      "{\"account_id\":%I64d,\"position_id\":%I64d,\"symbol\":\"%s\",\"r_multiple\":%.2f,\"profit\":%.2f,\"time\":\"%s\"}",
      accountId, positionId, JsonEscape(symbol), rMultiple, profit, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));

   int handle = FileOpen("journal\\rr_alerts.jsonl", FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
   if(handle == INVALID_HANDLE)
     {
      Print("TradeJournalEA: could not open rr_alerts.jsonl, err=", GetLastError());
      return;
     }
   FileSeek(handle, 0, SEEK_END);
   FileWriteString(handle, line + "\r\n");
   FileClose(handle);
  }

//+------------------------------------------------------------------+
// Ensures g_currentFile/g_prevHash point at the journal file for the
// current calendar month, recovering the hash-chain tip from disk
// (so a terminal restart mid-month doesn't break the chain).
//+------------------------------------------------------------------+
void LoadChainForCurrentMonth()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string monthFile = StringFormat("journal\\trades_%04d-%02d.jsonl", dt.year, dt.mon);

   if(monthFile == g_currentFile)
      return;

   g_currentFile = monthFile;
   string lastLine = ReadLastLine(g_currentFile);
   string hash = ExtractEntryHash(lastLine);
   g_prevHash = (hash != "") ? hash : GENESIS_HASH;
   g_lastProcessedKey = ExtractLastProcessedKey(lastLine);
  }

//+------------------------------------------------------------------+
// Pulls "<ticket>_<entry>" out of a raw journal line, so a freshly
// (re)initialized EA still recognizes "we already wrote this exact
// deal" instead of only guarding within one running session.
//+------------------------------------------------------------------+
string ExtractLastProcessedKey(const string &lastLine)
  {
   if(lastLine == "")
      return "";

   long ticket = 0;
   int tIdx = StringFind(lastLine, "\"ticket\":");
   if(tIdx >= 0)
     {
      int start = tIdx + StringLen("\"ticket\":");
      int end   = StringFind(lastLine, ",", start);
      if(end > start)
         ticket = StringToInteger(StringSubstr(lastLine, start, end - start));
     }

   string entry = "";
   int eIdx = StringFind(lastLine, "\"entry\":\"");
   if(eIdx >= 0)
     {
      int start = eIdx + StringLen("\"entry\":\"");
      int end   = StringFind(lastLine, "\"", start);
      if(end > start)
         entry = StringSubstr(lastLine, start, end - start);
     }

   return StringFormat("%I64d_%s", ticket, entry);
  }

//+------------------------------------------------------------------+
// Same idea as LoadChainForCurrentMonth, but for the separate
// position_events stream (SL/TP change log) - its own file, its own
// independent hash chain.
//+------------------------------------------------------------------+
void LoadEventsChainForCurrentMonth()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string monthFile = StringFormat("journal\\position_events_%04d-%02d.jsonl", dt.year, dt.mon);

   if(monthFile == g_eventsFile)
      return;

   g_eventsFile = monthFile;
   string lastLine = ReadLastLine(g_eventsFile);
   string hash = ExtractEntryHash(lastLine);
   g_eventsPrevHash = (hash != "") ? hash : GENESIS_HASH;
  }

//+------------------------------------------------------------------+
// Appends to the JSONL file for a specific year/month. The common case
// (live trading) is the current month - reuses the in-memory g_prevHash
// tip. A backfilled deal from an earlier month gets its own independent
// chain tip recovered fresh from disk, and never touches g_prevHash -
// that stays reserved for the current month's ongoing chain.
//+------------------------------------------------------------------+
string AppendDealLine(const int year, const int mon, const string fields)
  {
   string targetFile = StringFormat("journal\\trades_%04d-%02d.jsonl", year, mon);
   if(targetFile == g_currentFile)
     {
      string newHash = AppendChainedLine(g_currentFile, g_prevHash, fields);
      if(newHash != "")
         g_prevHash = newHash;
      return newHash;
     }

   string lastLine = ReadLastLine(targetFile);
   string hash = ExtractEntryHash(lastLine);
   string prevHash = (hash != "") ? hash : GENESIS_HASH;
   return AppendChainedLine(targetFile, prevHash, fields);
  }

//+------------------------------------------------------------------+
// Same ticket-parsing as ExtractLastProcessedKey, standalone so backfill
// can pull just the ticket number out of any journal line.
//+------------------------------------------------------------------+
long ExtractTicketFromLine(const string &line)
  {
   if(line == "")
      return 0;
   int tIdx = StringFind(line, "\"ticket\":");
   if(tIdx < 0)
      return 0;
   int start = tIdx + StringLen("\"ticket\":");
   int end   = StringFind(line, ",", start);
   if(end <= start)
      return 0;
   return StringToInteger(StringSubstr(line, start, end - start));
  }

//+------------------------------------------------------------------+
// The highest ticket number journaled anywhere, across every month's
// file - not just the current month - so backfill knows the true
// cutoff even if the terminal was offline across a month boundary.
//+------------------------------------------------------------------+
long FindOverallLastTicket()
  {
   string latestFile = "";
   string filename;
   long handle = FileFindFirst("journal\\trades_*.jsonl", filename);
   if(handle != INVALID_HANDLE)
     {
      do
        {
         if(filename > latestFile)
            latestFile = filename;
        }
      while(FileFindNext(handle, filename));
      FileFindClose(handle);
     }
   if(latestFile == "")
      return 0;
   string lastLine = ReadLastLine("journal\\" + latestFile);
   return ExtractTicketFromLine(lastLine);
  }

//+------------------------------------------------------------------+
// Catches up on deals that happened while this terminal was fully
// closed (e.g. traded from WebTrader/mobile with the desktop offline -
// those never reach a closed terminal's OnTradeTransaction at all).
// Safe to call on every OnInit: it's a no-op whenever nothing was
// actually missed, since the ticket cutoff always reflects exactly
// what's already been journaled. SL/TP-change history (position_events)
// can't be backfilled the same way - MT5 keeps no historical log of past
// modifications, only current live state, so that gap is unrecoverable.
//+------------------------------------------------------------------+
void BackfillMissedDeals()
  {
   long lastTicket = FindOverallLastTicket();

   if(!HistorySelect(0, TimeCurrent()))
     {
      Print("TradeJournalEA: backfill - HistorySelect failed, err=", GetLastError());
      return;
     }

   int total = HistoryDealsTotal();
   ulong candidates[];
   int count = 0;

   for(int i = 0; i < total; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0 || (long)ticket <= lastTicket)
         continue;
      long dealType = HistoryDealGetInteger(ticket, DEAL_TYPE);
      if(dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL)
         continue;
      ArrayResize(candidates, count + 1);
      candidates[count] = ticket;
      count++;
     }

   if(count == 0)
      return;

   ArraySort(candidates);

   for(int i = 0; i < count; i++)
      ProcessDeal(candidates[i], true);

   Print("TradeJournalEA: backfilled ", count, " deal(s) journaled while this terminal was offline");
  }

//+------------------------------------------------------------------+
// GET /api/ingest/last-ticket?account_id=N - the server's own answer to
// "what's the highest ticket you actually have for this account". Fills
// outTicket and returns true on a clean 200; returns false (leaving
// outTicket untouched) whenever the server can't be reached right now,
// so the caller knows to just try again later rather than mistake
// "unreachable" for "server has nothing yet".
//+------------------------------------------------------------------+
bool FetchServerLastTicket(const long accountId, long &outTicket)
  {
   string url     = InpServerUrl + "/api/ingest/last-ticket?account_id=" + IntegerToString(accountId);
   string headers = "X-Api-Token: " + InpApiToken + "\r\n";

   char   postData[]; // GET - no body
   char   result[];
   string resultHeaders;
   ResetLastError();
   int status = WebRequest("GET", url, headers, 5000, postData, result, resultHeaders);
   if(status != 200)
     {
      if(status == -1 && GetLastError() == 4060)
         Print("TradeJournalEA: reconcile check blocked - add ", InpServerUrl,
               " under Tools > Options > Expert Advisors > \"Allow WebRequest for listed URL\"");
      return false;
     }

   string body   = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   string marker = "\"last_ticket\":";
   int    pos    = StringFind(body, marker);
   if(pos < 0)
      return false;
   int start = pos + StringLen(marker);
   int end   = StringFind(body, "}", start);
   if(end <= start)
      return false;
   outTicket = StringToInteger(StringSubstr(body, start, end - start));
   return true;
  }

//+------------------------------------------------------------------+
// Drops the trailing ,"prev_hash":"...","entry_hash":"..."} that
// AppendChainedLine() adds when a line is written to disk, recovering
// the plain fields-only body (no surrounding braces) that PushToServer
// expects - so a reconciliation re-push sends exactly the same payload
// ProcessDeal() would have sent the first time.
//+------------------------------------------------------------------+
string StripHashSuffix(const string &line)
  {
   int pos = StringFind(line, ",\"prev_hash\":\"");
   if(pos < 0)
      return StringSubstr(line, 1, StringLen(line) - 2); // malformed/unexpected shape - best effort, still strip braces
   return StringSubstr(line, 1, pos - 1);
  }

//+------------------------------------------------------------------+
// Asks the server what its own highest known ticket is for this
// account, then re-pushes anything the local journal has beyond that.
// This exists for a different gap than BackfillMissedDeals() above:
// that one recovers deals the local journal itself never saw (terminal
// was closed); this one recovers deals that WERE journaled locally just
// fine but whose own PushToServer() call failed transiently (a dropped
// WebRequest, server hiccup) - the local file has no record of which
// pushes succeeded, so periodically re-checking with the server itself
// is the only way to close that gap. Runs once at OnInit (after the
// local backfill has already settled) and then every
// RECONCILE_CHECK_SECONDS via OnTimer. No-ops in local-only mode, and
// simply skips this round (tries again next time) if the server can't
// be reached at all right now.
//+------------------------------------------------------------------+
void ReconcileServerPushes()
  {
   if(InpServerUrl == "" || InpApiToken == "" || !g_serverUrlIsHttps)
      return;

   long accountId = AccountInfoInteger(ACCOUNT_LOGIN);
   long serverLastTicket = 0;
   if(!FetchServerLastTicket(accountId, serverLastTicket))
      return;

   string filenames[];
   int    fileCount = 0;
   string filename;
   long   findHandle = FileFindFirst("journal\\trades_*.jsonl", filename);
   if(findHandle != INVALID_HANDLE)
     {
      do
        {
         ArrayResize(filenames, fileCount + 1);
         filenames[fileCount] = filename;
         fileCount++;
        }
      while(FileFindNext(findHandle, filename));
      FileFindClose(findHandle);
     }
   ArraySort(filenames); // "trades_YYYY-MM.jsonl" sorts chronologically as plain text

   int pushed = 0;
   for(int f = 0; f < fileCount; f++)
     {
      int fh = FileOpen("journal\\" + filenames[f], FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE, 0, CP_UTF8);
      if(fh == INVALID_HANDLE)
         continue;

      while(!FileIsEnding(fh))
        {
         string line = FileReadString(fh);
         if(StringLen(line) == 0)
            continue;

         long ticket = ExtractTicketFromLine(line);
         if(ticket <= serverLastTicket)
            continue;

         PushToServer("/api/ingest/deal", "{" + StripHashSuffix(line) + "}");
         pushed++;
        }
      FileClose(fh);
     }

   if(pushed > 0)
      Print("TradeJournalEA: reconciled ", pushed, " deal(s) the server was missing");
  }

//+------------------------------------------------------------------+
// Trade Replay: real MT5 price bars for a closed position. Every one
// of these six timeframes
// gets its own export with real history BEFORE the entry (not just a
// padded window around the trade itself) - a trader re-analyzing "why
// did I enter here" needs to see the market structure leading into the
// entry, which the first version of this feature didn't provide and
// the user explicitly asked for after trying it live.
//+------------------------------------------------------------------+
// D1 dropped per explicit user feedback: with only a 2-day pre-entry
// window (see REPLAY_HISTORY_SECONDS below), a D1 chart would show
// essentially 2 candles - not useful at that timeframe, so it's not
// exported at all rather than shipping something meaningless.
#define REPLAY_TF_COUNT 5
string          g_replayTfLabels[REPLAY_TF_COUNT]  = {"M1", "M5", "M15", "H1", "H4"};
ENUM_TIMEFRAMES g_replayTfPeriods[REPLAY_TF_COUNT] = {PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_H1, PERIOD_H4};

// Per explicit user feedback: the point of this feature is re-judging
// the setup, not watching the trade play out again - so ask for as much
// real history BEFORE the entry as MT5 actually has (CopyRates just
// returns fewer bars than requested if less history is cached locally;
// it never errors), and essentially nothing after the close.
// Per explicit user feedback: a fixed WALL-CLOCK window before entry
// (not "as much as MT5 has"), so it scales sensibly per timeframe (2
// days is ~2880 M1 bars but only 12 H4 bars) instead of the same
// artificial bar count meaning wildly different real time spans.
#define REPLAY_HISTORY_SECONDS (2 * 86400)
#define REPLAY_BARS_AFTER 3 // just enough that the closing candle itself isn't clipped at the window edge
// Real, load-bearing cap on bars per timeframe per trade - NOT just a
// pathological-case safety net. A swing trade held for days/weeks
// (common on crypto, not rare on forex either) makes the pre-entry
// window below the smaller concern: at the old 5000-bar ceiling, an H1
// or H4 chart for a multi-week trade could span MONTHS of real time
// (5000 H4 bars = ~833 days) - exactly what a user reported seeing
// ("I see history back to the start of summer"), not a "2-day history"
// window as intended. 750 keeps every timeframe's worst case sane
// (H4: ~125 days, H1: ~31 days, M15: ~7.8 days, M5: ~2.6 days, M1: ~12.5h)
// while still comfortably covering realistic swing-trade durations on
// the coarser timeframes - the finer ones naturally lose full-trade
// coverage for very long holds, which is expected: nobody reads M1
// detail across a month-long position anyway. When this binds, the
// window shifts to end at the close (pre-entry context shrinks first,
// then the earliest part of the trade itself if needed) rather than
// growing without bound.
#define REPLAY_MAX_BARS_PER_TF 750

//+------------------------------------------------------------------+
// Finds the "in" deal's time for a position by its position_id - needed
// because ProcessDeal only sees the "out" deal's own fields when a
// position closes; the actual open moment lives on a separate, earlier
// deal. HistorySelect populates the ticket-indexed view HistoryDealsTotal/
// HistoryDealGetTicket need - HistoryDealSelect(ticket) alone (used
// elsewhere in this file for single-deal property access) does not.
//+------------------------------------------------------------------+
long FindPositionOpenTimeMsc(const long positionId)
  {
   if(!HistorySelect(0, TimeCurrent()))
      return 0;
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if((long)HistoryDealGetInteger(ticket, DEAL_POSITION_ID) != positionId)
         continue;
      if((long)HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_IN)
         return (long)HistoryDealGetInteger(ticket, DEAL_TIME_MSC);
     }
   return 0;
  }

// Same search, but for the position's "out"/"out_by" deal - used only by
// ReconcileMissingBars() below, where (unlike the live ProcessDeal call
// site, which already has the close time to hand) the close time needs
// to be rediscovered for an older position missing its bars.
long FindPositionCloseTimeMsc(const long positionId)
  {
   if(!HistorySelect(0, TimeCurrent()))
      return 0;
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if((long)HistoryDealGetInteger(ticket, DEAL_POSITION_ID) != positionId)
         continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
         return (long)HistoryDealGetInteger(ticket, DEAL_TIME_MSC);
     }
   return 0;
  }

//+------------------------------------------------------------------+
// Exports real CopyRates() bars for ONE timeframe, covering real
// history before the entry through a little past the close, and pushes
// them to /api/ingest/bars - same best-effort, never-blocks-local-
// journaling contract as every other push in this file. A symbol/timeframe combo with no
// history available locally (CopyRates returns <= 0 - e.g. a brand-new
// chart the terminal hasn't cached bars for yet) just skips silently;
// the other timeframes are pushed independently regardless.
//+------------------------------------------------------------------+
void PushTradeReplayBarsForTimeframe(const long positionId, const string symbol, const long openTimeMsc,
                                      const long closeTimeMsc, const string tfLabel, const ENUM_TIMEFRAMES period)
  {
   int periodSeconds = PeriodSeconds(period);

   datetime fromTime = (datetime)(openTimeMsc / 1000) - REPLAY_HISTORY_SECONDS;
   datetime toTime   = (datetime)(closeTimeMsc / 1000) + periodSeconds * REPLAY_BARS_AFTER;
   long spanBars = (long)((toTime - fromTime) / periodSeconds);
   if(spanBars > REPLAY_MAX_BARS_PER_TF)
      fromTime = toTime - periodSeconds * REPLAY_MAX_BARS_PER_TF;

   MqlRates rates[];
   int copied = CopyRates(symbol, period, fromTime, toTime, rates);
   if(copied <= 0)
     {
      Print("TradeJournalEA: no replay bars available for position ", positionId,
            " symbol=", symbol, " tf=", tfLabel, " err=", GetLastError());
      return;
     }

   string barsJson = "";
   for(int i = 0; i < copied; i++)
     {
      if(barsJson != "")
         barsJson += ",";
      barsJson += StringFormat(
         "{\"time\":%I64d,\"open\":%.5f,\"high\":%.5f,\"low\":%.5f,\"close\":%.5f}",
         (long)rates[i].time, rates[i].open, rates[i].high, rates[i].low, rates[i].close);
     }

   long accountId = AccountInfoInteger(ACCOUNT_LOGIN);
   string payload = StringFormat(
      "{\"account_id\":%I64d,\"position_id\":%I64d,\"timeframe\":\"%s\",\"bars\":[%s]}",
      accountId, positionId, tfLabel, barsJson);

   PushToServer("/api/ingest/bars", payload);
  }

//+------------------------------------------------------------------+
// Exports every timeframe (M1/M5/M15/H1/H4/D1) for one closed position -
// each is an independent CopyRates()+push, so one timeframe having no
// local history yet never blocks the others.
//+------------------------------------------------------------------+
void PushTradeReplayBars(const long positionId, const string symbol, const long openTimeMsc, const long closeTimeMsc)
  {
   if(InpServerUrl == "" || InpApiToken == "" || !g_serverUrlIsHttps || openTimeMsc <= 0)
      return;

   for(int i = 0; i < REPLAY_TF_COUNT; i++)
      PushTradeReplayBarsForTimeframe(positionId, symbol, openTimeMsc, closeTimeMsc, g_replayTfLabels[i], g_replayTfPeriods[i]);
  }

//+------------------------------------------------------------------+
// GET /api/ingest/missing-bars?account_id=N - parses the
// "missing_position_ids":[...] array out of the JSON response into
// outPositionIds, returning how many were found. No real JSON parser
// needed since we control the exact shape the server returns.
//+------------------------------------------------------------------+
int FetchMissingBarsPositionIds(const long accountId, long &outPositionIds[])
  {
   string url     = InpServerUrl + "/api/ingest/missing-bars?account_id=" + IntegerToString(accountId);
   string headers = "X-Api-Token: " + InpApiToken + "\r\n";

   char   postData[]; // GET - no body
   char   result[];
   string resultHeaders;
   ResetLastError();
   int status = WebRequest("GET", url, headers, 5000, postData, result, resultHeaders);
   if(status != 200)
      return 0;

   string body   = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   string marker = "\"missing_position_ids\":[";
   int    start  = StringFind(body, marker);
   if(start < 0)
      return 0;
   start += StringLen(marker);
   int end = StringFind(body, "]", start);
   if(end < 0)
      return 0;

   string inner = StringSubstr(body, start, end - start);
   if(StringLen(inner) == 0)
      return 0;

   string parts[];
   int count = StringSplit(inner, ',', parts);
   ArrayResize(outPositionIds, count);
   for(int i = 0; i < count; i++)
      outPositionIds[i] = StringToInteger(parts[i]);
   return count;
  }

//+------------------------------------------------------------------+
// Companion to ReconcileServerPushes() for replay bars: a closed
// position's deal can land fine while its separate
// PushTradeReplayBars() call fails. Bars can always be re-derived from
// MT5's own broker-side history via CopyRates - so this just re-runs
// the same export for whichever closed positions the
// server reports as still missing them. Same run cadence as the other
// reconciliation passes (OnInit + every RECONCILE_CHECK_SECONDS).
//+------------------------------------------------------------------+
void ReconcileMissingBars()
  {
   if(InpServerUrl == "" || InpApiToken == "" || !g_serverUrlIsHttps)
      return;

   long accountId = AccountInfoInteger(ACCOUNT_LOGIN);
   long missingPositionIds[];
   int  count = FetchMissingBarsPositionIds(accountId, missingPositionIds);

   int pushed = 0;
   for(int i = 0; i < count; i++)
     {
      long positionId = missingPositionIds[i];
      long openTimeMsc = FindPositionOpenTimeMsc(positionId);
      long closeTimeMsc = FindPositionCloseTimeMsc(positionId);
      if(openTimeMsc <= 0 || closeTimeMsc <= 0)
         continue;
      string symbol = "";
      if(HistorySelect(0, TimeCurrent()))
        {
         int total = HistoryDealsTotal();
         for(int d = total - 1; d >= 0; d--)
           {
            ulong ticket = HistoryDealGetTicket(d);
            if(ticket != 0 && (long)HistoryDealGetInteger(ticket, DEAL_POSITION_ID) == positionId)
              {
               symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
               break;
              }
           }
        }
      if(symbol == "")
         continue;
      PushTradeReplayBars(positionId, symbol, openTimeMsc, closeTimeMsc);
      pushed++;
     }

   if(pushed > 0)
      Print("TradeJournalEA: reconciled replay bars for ", pushed, " position(s)");
  }

//+------------------------------------------------------------------+
int FindPositionIndex(const long ticket)
  {
   for(int i = 0; i < ArraySize(g_evPosTicket); i++)
      if(g_evPosTicket[i] == ticket)
         return i;
   return -1;
  }

void RememberPositionSlTp(const long ticket, const double sl, const double tp)
  {
   int idx = FindPositionIndex(ticket);
   if(idx < 0)
     {
      idx = ArraySize(g_evPosTicket);
      ArrayResize(g_evPosTicket, idx + 1);
      ArrayResize(g_evPosSl, idx + 1);
      ArrayResize(g_evPosTp, idx + 1);
      g_evPosTicket[idx] = ticket;
     }
   g_evPosSl[idx] = sl;
   g_evPosTp[idx] = tp;
  }

// Drops a position from the SL/TP tracker once it's fully closed, so the
// arrays don't grow forever over months of trading.
void ForgetPosition(const long ticket)
  {
   int idx = FindPositionIndex(ticket);
   if(idx < 0)
      return;
   int last = ArraySize(g_evPosTicket) - 1;
   g_evPosTicket[idx] = g_evPosTicket[last];
   g_evPosSl[idx]     = g_evPosSl[last];
   g_evPosTp[idx]     = g_evPosTp[last];
   ArrayResize(g_evPosTicket, last);
   ArrayResize(g_evPosSl, last);
   ArrayResize(g_evPosTp, last);
  }

//+------------------------------------------------------------------+
// Fires on any position change (SL/TP edits chief among them). The first
// time we see a given position here is just its opening state - already
// covered by the "in" deal - so it's recorded silently to seed the
// tracker, not logged as an event. Only real SL/TP changes after that
// get appended to the position_events journal.
//+------------------------------------------------------------------+
void HandlePositionEvent(const MqlTradeTransaction &trans)
  {
   long ticket = (long)trans.position;
   if(ticket == 0)
      return;

   int idx = FindPositionIndex(ticket);
   bool firstSeen = (idx < 0);
   double prevSl = firstSeen ? -1.0 : g_evPosSl[idx];
   double prevTp = firstSeen ? -1.0 : g_evPosTp[idx];
   double newSl  = trans.price_sl;
   double newTp  = trans.price_tp;

   bool slChanged = !firstSeen && MathAbs(newSl - prevSl) > 0.0000001;
   bool tpChanged = !firstSeen && MathAbs(newTp - prevTp) > 0.0000001;

   RememberPositionSlTp(ticket, newSl, newTp);

   if(firstSeen || (!slChanged && !tpChanged))
      return;

   string kind = (slChanged && tpChanged) ? "sl_tp_changed" : slChanged ? "sl_changed" : "tp_changed";
   long   accountId = AccountInfoInteger(ACCOUNT_LOGIN);
   datetime now = TimeCurrent();
   string isoTime = TimeToString(now, TIME_DATE | TIME_SECONDS);

   string fields = StringFormat(
      "\"account_id\":%I64d,\"position_id\":%I64d,\"symbol\":\"%s\",\"event\":\"%s\","
      "\"sl\":%.5f,\"tp\":%.5f,\"prev_sl\":%.5f,\"prev_tp\":%.5f,\"time\":\"%s\",\"time_msc\":%I64d",
      accountId, ticket, JsonEscape(trans.symbol), kind,
      newSl, newTp, prevSl, prevTp, isoTime, (long)now * 1000);

   LoadEventsChainForCurrentMonth();
   string newHash = AppendChainedLine(g_eventsFile, g_eventsPrevHash, fields);
   if(newHash == "")
     {
      Print("TradeJournalEA: FAILED to append position-event line for position ", ticket);
      return;
     }
   g_eventsPrevHash = newHash;
  }

//+------------------------------------------------------------------+
string EntryTypeToString(const long entry)
  {
   switch((int)entry)
     {
      case DEAL_ENTRY_IN:     return "in";
      case DEAL_ENTRY_OUT:    return "out";
      case DEAL_ENTRY_INOUT:  return "inout";
      case DEAL_ENTRY_OUT_BY: return "out_by";
      default:                return "unknown";
     }
  }

string ReasonToString(const long reason)
  {
   switch((int)reason)
     {
      case DEAL_REASON_CLIENT:   return "manual";
      case DEAL_REASON_MOBILE:   return "mobile";
      case DEAL_REASON_WEB:      return "web";
      case DEAL_REASON_EXPERT:   return "expert";
      case DEAL_REASON_SL:       return "sl";
      case DEAL_REASON_TP:       return "tp";
      case DEAL_REASON_SO:       return "stopout";
      case DEAL_REASON_ROLLOVER: return "rollover";
      case DEAL_REASON_VMARGIN:  return "vmargin";
      case DEAL_REASON_SPLIT:    return "split";
      default:                   return "unknown";
     }
  }

string DealTypeToString(const long type)
  {
   switch((int)type)
     {
      case DEAL_TYPE_BUY:  return "buy";
      case DEAL_TYPE_SELL: return "sell";
      default:             return "other";
     }
  }

//+------------------------------------------------------------------+
// Everything needed to journal one BUY/SELL deal - shared by live
// OnTradeTransaction events and BackfillMissedDeals(). Routes to the
// JSONL file for the deal's OWN month via AppendDealLine(), so a
// backfilled historical deal always lands in the right month's file,
// not whatever month happens to be current right now.
//+------------------------------------------------------------------+
void ProcessDeal(const ulong ticket, const bool isBackfilled = false)
  {
   if(!HistoryDealSelect(ticket))
     {
      Print("TradeJournalEA: could not select deal ", ticket);
      return;
     }

   // Skip balance/credit deals (deposits, withdrawals) - not trades.
   long dealType = HistoryDealGetInteger(ticket, DEAL_TYPE);
   if(dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL)
      return;

   long   positionId = HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
   string symbol     = HistoryDealGetString(ticket, DEAL_SYMBOL);
   long   magic      = HistoryDealGetInteger(ticket, DEAL_MAGIC);
   long   entryType  = HistoryDealGetInteger(ticket, DEAL_ENTRY);

   // MT5 can re-fire OnTradeTransaction for the same deal (observed with
   // web/mobile-originated trades syncing into this terminal) - without
   // this guard that writes the exact same line to the journal more than
   // once, which breaks the strict hash chain (each line's prev_hash
   // must be the single preceding entry, not an already-consumed one).
   string dealKey = StringFormat("%I64u_%s", ticket, EntryTypeToString(entryType));
   if(dealKey == g_lastProcessedKey)
     {
      Print("TradeJournalEA: skipping duplicate re-fired transaction for deal ", ticket);
      return;
     }

   double volume     = HistoryDealGetDouble(ticket, DEAL_VOLUME);
   double price      = HistoryDealGetDouble(ticket, DEAL_PRICE);
   double sl         = HistoryDealGetDouble(ticket, DEAL_SL);
   double tp         = HistoryDealGetDouble(ticket, DEAL_TP);
   long   timeMsc    = HistoryDealGetInteger(ticket, DEAL_TIME_MSC);
   double commission = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   double swap       = HistoryDealGetDouble(ticket, DEAL_SWAP);
   double profit     = HistoryDealGetDouble(ticket, DEAL_PROFIT);
   long   reason     = HistoryDealGetInteger(ticket, DEAL_REASON);
   string comment    = HistoryDealGetString(ticket, DEAL_COMMENT);
   long   accountId  = AccountInfoInteger(ACCOUNT_LOGIN);

   // MT5 has already applied this deal to the account by the time this
   // runs, so these reflect balance/equity *after* this deal - lets the
   // dashboard derive each account's true starting balance (balance_after
   // minus this deal's own effect) straight from MT5 instead of a
   // hand-typed config value. For a backfilled deal this is the CURRENT
   // balance/equity, not the historical value at that past moment - MT5
   // doesn't expose historical account state, so this is a known
   // approximation for anything backfilled after the fact.
   double balanceAfter = AccountInfoDouble(ACCOUNT_BALANCE);
   double equityAfter  = AccountInfoDouble(ACCOUNT_EQUITY);

   string isoTime = TimeToString((datetime)(timeMsc / 1000), TIME_DATE | TIME_SECONDS);

   // isBackfilled means this deal is being journaled well after it
   // actually happened (terminal was closed/offline at the real moment -
   // see BackfillMissedDeals) - balance_after/equity_after are today's
   // live numbers, not the true value at that past instant. Flagged so
   // the dashboard can warn the trader those two fields aren't the real
   // historical values, instead of presenting them as if they were.
   string fields = StringFormat(
      "\"account_id\":%I64d,\"ticket\":%I64u,\"position_id\":%I64d,\"symbol\":\"%s\","
      "\"magic\":%I64d,\"deal_type\":\"%s\",\"entry\":\"%s\",\"volume\":%.2f,\"price\":%.5f,"
      "\"sl\":%.5f,\"tp\":%.5f,\"time\":\"%s\",\"time_msc\":%I64d,\"commission\":%.2f,"
      "\"swap\":%.2f,\"profit\":%.2f,\"reason\":\"%s\",\"comment\":\"%s\","
      "\"balance_after\":%.2f,\"equity_after\":%.2f,\"backfilled\":%s",
      accountId, ticket, positionId, JsonEscape(symbol),
      magic, DealTypeToString(dealType), EntryTypeToString(entryType), volume, price,
      sl, tp, isoTime, timeMsc, commission,
      swap, profit, ReasonToString(reason), JsonEscape(comment),
      balanceAfter, equityAfter, isBackfilled ? "true" : "false");

   MqlDateTime dealDt;
   TimeToStruct((datetime)(timeMsc / 1000), dealDt);

   LoadChainForCurrentMonth(); // cheap no-op unless the month just rolled over
   string newHash = AppendDealLine(dealDt.year, dealDt.mon, fields);
   if(newHash == "")
     {
      Print("TradeJournalEA: FAILED to append journal line for deal ", ticket);
      return;
     }
   g_lastProcessedKey = dealKey;

   PushToServer("/api/ingest/deal", "{" + fields + "}");

   if(entryType == DEAL_ENTRY_OUT || entryType == DEAL_ENTRY_OUT_BY)
     {
      long openTimeMsc = FindPositionOpenTimeMsc(positionId);
      if(openTimeMsc > 0)
         PushTradeReplayBars(positionId, symbol, openTimeMsc, timeMsc);
      ForgetPosition(positionId);
     }
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_POSITION)
     {
      HandlePositionEvent(trans);
      return;
     }

   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ProcessDeal(trans.deal);
  }

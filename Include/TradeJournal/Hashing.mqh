//+------------------------------------------------------------------+
//| Hashing.mqh                                                      |
//| SHA-256 hex helper + append-only hash-chain writer for           |
//| TradeJournalEA. Every journal line embeds prev_hash/entry_hash   |
//| so any retroactive edit of an earlier line breaks the chain.     |
//+------------------------------------------------------------------+
#property strict

string Sha256Hex(const string &text)
  {
   uchar data[], key[], result[];
   StringToCharArray(text, data, 0, StringLen(text), CP_UTF8);
   // StringToCharArray appends a trailing zero; strip it before hashing.
   int len = ArraySize(data);
   if(len > 0 && data[len - 1] == 0)
      ArrayResize(data, len - 1);

   int hashLen = CryptEncode(CRYPT_HASH_SHA256, data, key, result);
   if(hashLen <= 0)
      return "";

   string hex = "";
   for(int i = 0; i < hashLen; i++)
      hex += StringFormat("%02x", result[i]);
   return hex;
  }

string JsonEscape(const string &raw)
  {
   string out = raw;
   StringReplace(out, "\\", "\\\\");
   StringReplace(out, "\"", "\\\"");
   StringReplace(out, "\n", "\\n");
   StringReplace(out, "\r", "");
   return out;
  }

// Reads the last non-empty line of a text file, or "" if the file
// doesn't exist / is empty. Used on EA init to recover the hash chain
// tip after a terminal restart, and by callers to extract entry_hash.
string ReadLastLine(const string relPath)
  {
   if(!FileIsExist(relPath))
      return "";

   int handle = FileOpen(relPath, FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE, 0, CP_UTF8);
   if(handle == INVALID_HANDLE)
      return "";

   string last = "";
   while(!FileIsEnding(handle))
     {
      string line = FileReadString(handle);
      if(StringLen(line) > 0)
         last = line;
     }
   FileClose(handle);
   return last;
  }

// Pulls the entry_hash value out of a previously-written JSON line.
// Deliberately minimal (no real JSON parser) since we control the
// exact field order/format we write in TradeJournalEA.mq5.
string ExtractEntryHash(const string &jsonLine)
  {
   string marker = "\"entry_hash\":\"";
   int pos = StringFind(jsonLine, marker);
   if(pos < 0)
      return "";
   int start = pos + StringLen(marker);
   int end = StringFind(jsonLine, "\"", start);
   if(end < 0)
      return "";
   return StringSubstr(jsonLine, start, end - start);
  }

// Appends one hash-chained JSON line to relPath (inside MQL5\Files\).
// fieldsJson must be the inner "key":value,... body WITHOUT braces.
// Returns the new entry_hash, or "" on failure.
string AppendChainedLine(const string relPath, const string prevHash, const string fieldsJson)
  {
   string payload = fieldsJson + ",\"prev_hash\":\"" + prevHash + "\"";
   string entryHash = Sha256Hex(payload);
   string line = "{" + payload + ",\"entry_hash\":\"" + entryHash + "\"}";

   // FILE_READ|FILE_WRITE opens for append-at-end without truncating;
   // we then seek to EOF explicitly so concurrent terminal restarts
   // never overwrite prior bytes.
   int handle = FileOpen(relPath, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ, 0, CP_UTF8);
   if(handle == INVALID_HANDLE)
      return "";

   FileSeek(handle, 0, SEEK_END);
   FileWriteString(handle, line + "\r\n");
   FileFlush(handle);
   FileClose(handle);
   return entryHash;
  }

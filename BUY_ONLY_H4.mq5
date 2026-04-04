//+------------------------------------------------------------------+
//|                                               GoldPro_EA.mq5     |
//|     SMA9 x EMA21 | Visual Box | Hidden SL/TP | Breakeven         |
//|     Buy-only — H4 — Magic 203103 | Prefix GPB_H4_*            |
//|     Bản riêng H4: không trùng Magic với các khung/hướng khác   |
//+------------------------------------------------------------------+
#property copyright "GoldPro EA v5.1"
#property version   "5.10"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//====================================================================
//  INPUTS
//====================================================================
input int    FastLen          = 9;
input int    SlowLen          = 21;

input double RR               = 3.0;
input int    LookbackSwing    = 20;
input double MaxLotSize       = 5.0;

// Lot: mặc định theo vốn — mỗi BalanceLotStep (vd 1000) tăng LotPerBalanceStep (vd 0.01). 1000→0.01, 2000→0.02...
input bool   UseRiskBasedLot   = false;
input double BalanceLotStep    = 1000.0;
input double LotPerBalanceStep = 0.01;
input double RiskPercent       = 1.0; // chỉ dùng khi UseRiskBasedLot = true

input ulong  MagicNumber      = 203103; // Giữ khác Magic của EA SELL khi chạy cùng symbol
input int    Slippage         = 10;
input bool   CloseOnOpposite  = true;

input bool   UseSessionFilter = false;
input int    SessionStartHour = 7;
input int    SessionEndHour   = 20;

input bool   ShowInfo         = true;
input bool   DrawMAOnChart    = true;
input int    MADrawBars       = 200;

input int    BoxExtendBars    = 100;
input color  ColorSLBox       = clrRed;
input color  ColorTPBox       = clrGreen;
input color  ColorEntryLine   = clrWhite;

// BUY: mở 2 lệnh cùng hướng. Khi giá đạt BreakevenTriggerPct % đường Entry→TP: đóng 1 lệnh, lệnh còn lại
// dời SL ẩn (BreakevenLockPct % quãng Entry→TP phía trên entry).
input double BreakevenTriggerPct = 30.0;
input double BreakevenLockPct    = 10.0;

input string EntryMode        = "BUY ONLY"; // OPEN_NEXT_BAR | CLOSE_SIGNAL

input bool   UseATRFilter     = true;
input int    ATRPeriod        = 14;
input double ATRMinMultiplier = 0.5;

input bool   UseAngleFilter   = true;
input double MinSlopePoints   = 3.0;

input bool   UseCooldown      = true;
input int    CooldownBars     = 3;

input double MinRiskPoints    = 50.0;

input bool   SkipFiltersOnReverse = false;

input bool   UseDailyLossLimit = true;
input double DailyLossLimit    = 100.0; // đơn vị tiền tài khoản (account currency)
input double SLExtraPrice     = 10.0;  // cộng thẳng vào giá SL (vd 2000 → 2010)

input bool   TG_Enable        = true;
input string TG_BotToken      = "8670705580:AAGp4brfAAYyqJYgyflhAdiCNt_bDJwLSqI";
input string TG_ChatID        = "8163537465";

//====================================================================
#define NO_TRADE -1

//====================================================================
double AddExtraToSlPrice(double sl)
{
   if(SLExtraPrice<=0.0) return NormalizeDouble(sl,_Digits);
   return NormalizeDouble(sl+SLExtraPrice,_Digits);
}

//====================================================================
struct TradeState
{
   ulong  ticket;   // lệnh giữ đến TP/SL (sau partial chỉ còn ticket)
   ulong  ticket2;  // lệnh thứ 2 — đóng khi đạt % tiến độ; 0 = không có / đã đóng
   int    dir;
   double entry;
   double sl;
   double tp;
   bool   active;
   bool   breakevenDone;
};

TradeState gTrade;

datetime lastBarTime  = 0;
int      fastHandle   = INVALID_HANDLE;
int      slowHandle   = INVALID_HANDLE;
int      atrHandle    = INVALID_HANDLE;

datetime lastLossBarTime = 0;
int      barsSinceLoss   = 0;

double   dayStartBalance = 0.0;
datetime dayStartTime    = 0;
int      dayWins         = 0;
int      dayLosses       = 0;
double   dayGross        = 0.0;

datetime lastBuyFireBar = 0;

//====================================================================
// Comment lệnh cố định H4_BUY — Magic riêng; đối tượng chart prefix GPB_H4_
const string EA_TF_TAG = "H4";

string ChartTfShort()
{
   return EA_TF_TAG;
}

string OrderCommentWithTf(const string dirTag)
{
   return EA_TF_TAG+"_"+dirTag;
}

//====================================================================
bool SplitLotInTwo(double total, double &lot1, double &lot2)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(total < 2.0*minL - 1e-12) return false;
   lot1 = MathFloor((total/2.0)/step)*step;
   if(lot1 < minL) lot1 = minL;
   lot2 = NormalizeDouble(total - lot1, 2);
   if(lot2 < minL)
   {
      lot2 = minL;
      lot1 = NormalizeDouble(total - lot2, 2);
   }
   return (lot1 >= minL && lot2 >= minL);
}

double GetFloatingPnLBoth()
{
   double v = 0.0;
   if(gTrade.ticket > 0 && posInfo.SelectByTicket(gTrade.ticket))
      v += posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
   if(gTrade.ticket2 > 0 && posInfo.SelectByTicket(gTrade.ticket2))
      v += posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
   return v;
}

//====================================================================
//  TELEGRAM
//====================================================================
bool TG_Send(string message)
{
   if(!TG_Enable) return true;
   if(TG_BotToken == "YOUR_BOT_TOKEN" || TG_ChatID == "YOUR_CHAT_ID")
   { Print("TG: Token/ChatID not configured"); return false; }

   string encoded = message;
   StringReplace(encoded, "\n", "%0A");
   StringReplace(encoded, " ",  "%20");
   StringReplace(encoded, "+",  "%2B");
   StringReplace(encoded, "#",  "%23");
   StringReplace(encoded, "&",  "%26");
   StringReplace(encoded, "=",  "%3D");

   string url = "https://api.telegram.org/bot" + TG_BotToken +
                "/sendMessage?chat_id=" + TG_ChatID +
                "&text=" + encoded + "&parse_mode=HTML";

   char post[], result[]; string headers;
   int res = WebRequest("GET", url, "", 5000, post, result, headers);
   if(res == -1) { Print("TG error: ", GetLastError()); return false; }
   return true;
}

string TG_Emoji(int dir)     { return "🟢"; }
string TG_DirStr(int dir)    { return "BUY ▲"; }
string TG_PriceStr(double p) { return DoubleToString(p, _Digits); }
string TG_MoneyStr(double v, string cur)
{ return (v >= 0 ? "+" : "") + DoubleToString(v, 2) + " " + cur; }

void TG_OnStart()
{
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   string msg =
      "🤖 <b> BUY ONLY — STARTED</b>\n" +
      "━━━━━━━━━━━━━━━━━━\n" +
      "📊 Symbol    : " + _Symbol + "  " + EnumToString(Period()) + "\n" +
      "🏦 Account   : " + AccountInfoString(ACCOUNT_NAME) + "\n" +
      "💰 Balance   : " + DoubleToString(bal, 2) + " " + cur + "\n" +
      "🎯 Direction : BUY ONLY\n" +
      "⚙️  SMA/EMA   : " + IntegerToString(FastLen) + " / " + IntegerToString(SlowLen) + "\n" +
      "🎯 RR        : 1:" + DoubleToString(RR, 1) + "\n" +
      (UseRiskBasedLot
         ? "🛡 Lot       : " + DoubleToString(RiskPercent, 1) + "% risk\n"
         : "🛡 Lot       : " + DoubleToString(LotPerBalanceStep, 2) + " / " + DoubleToString(BalanceLotStep, 0) + " " + cur + "\n") +
      "━━━━━━━━━━━━━━━━━━";
   TG_Send(msg);
}

void TG_OnSignal(int dir, double entry, double sl, double tp, double lot)
{
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk = MathAbs(entry - sl);
   string msg =
      TG_Emoji(dir) + " <b>SIGNAL — " + TG_DirStr(dir) + "</b>\n" +
      "━━━━━━━━━━━━━━━━━━\n" +
      "📌 Symbol : " + _Symbol + "\n" +
      "📍 Entry  : " + TG_PriceStr(entry) + "\n" +
      "🛑 SL     : " + TG_PriceStr(sl) + "  (" + DoubleToString(risk/_Point,0) + " pts)\n" +
      "🎯 TP     : " + TG_PriceStr(tp) + "  (" + DoubleToString(MathAbs(tp-entry)/_Point,0) + " pts)\n" +
      "📦 Lot    : " + DoubleToString(lot, 2) + "\n" +
      "⏱ Time   : " + TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES) + "\n" +
      "━━━━━━━━━━━━━━━━━━";
   TG_Send(msg);
}

void TG_OnOpen(int dir, double entry, double sl, double tp, double lot, ulong ticket)
{
   string msg =
      TG_Emoji(dir) + " <b>ORDER OPENED — " + TG_DirStr(dir) + "</b>\n" +
      "━━━━━━━━━━━━━━━━━━\n" +
      "🎫 Ticket : #" + IntegerToString((long)ticket) + "\n" +
      "📍 Entry  : " + TG_PriceStr(entry) + "\n" +
      "🛑 SL     : " + TG_PriceStr(sl) + "  <i>(hidden)</i>\n" +
      "🎯 TP     : " + TG_PriceStr(tp) + "  <i>(hidden)</i>\n" +
      "📦 Lot    : " + DoubleToString(lot, 2) + "\n" +
      "⏱ Time   : " + TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES) + "\n" +
      "━━━━━━━━━━━━━━━━━━";
   TG_Send(msg);
}

void TG_OnOpenTwoBuy(double entry, double sl, double tp, double lot1, double lot2, ulong tk1, ulong tk2)
{
   string msg =
      TG_Emoji((int)POSITION_TYPE_BUY) + " <b>2 ORDERS OPENED — BUY</b>\n" +
      "━━━━━━━━━━━━━━━━━━\n" +
      "🎫 #1 #" + IntegerToString((long)tk1) + "  Lot " + DoubleToString(lot1, 2) + "\n" +
      "🎫 #2 #" + IntegerToString((long)tk2) + "  Lot " + DoubleToString(lot2, 2) + "  <i>(đóng @ "+DoubleToString(BreakevenTriggerPct,0)+"%→TP)</i>\n" +
      "📍 Entry  : " + TG_PriceStr(entry) + "\n" +
      "🛑 SL/TP : " + TG_PriceStr(sl) + " / " + TG_PriceStr(tp) + "  <i>(hidden)</i>\n" +
      "⏱ Time   : " + TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES) + "\n" +
      "━━━━━━━━━━━━━━━━━━";
   TG_Send(msg);
}

void TG_OnBreakeven(double newSL, double entry, double progress)
{
   string msg =
      "⚡ <b>BREAKEVEN / LOCK</b>\n" +
      "━━━━━━━━━━━━━━━━━━\n" +
      "🎫 Ticket : #" + IntegerToString((long)gTrade.ticket) + "\n" +
      "📍 Entry  : " + TG_PriceStr(entry) + "\n" +
      "🛑 SL mới : " + TG_PriceStr(newSL) + "  (khóa ~" + DoubleToString(BreakevenLockPct, 0) + "% đường TP)\n" +
      "📈 Tiến độ: " + DoubleToString(progress, 1) + "% →TP\n" +
      "⏱ Time   : " + TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES) + "\n" +
      "━━━━━━━━━━━━━━━━━━";
   TG_Send(msg);
}

void TG_OnClose(string reason, double entry, double closePrice,
                double pnlMoney, double pnlPts, ulong ticket)
{
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double balPct = (bal > 0) ? (pnlMoney / (bal - pnlMoney) * 100.0) : 0.0;
   string emoji = (StringFind(reason,"TP")>=0) ? "✅" : (StringFind(reason,"BE")>=0) ? "💛" : "❌";
   string msg =
      emoji + " <b>ORDER CLOSED — " + reason + "</b>\n" +
      "━━━━━━━━━━━━━━━━━━\n" +
      "🎫 Ticket    : #" + IntegerToString((long)ticket) + "\n" +
      "📍 Entry     : " + TG_PriceStr(entry) + "\n" +
      "🏁 Close     : " + TG_PriceStr(closePrice) + "\n" +
      "📊 P&L (pts) : " + (pnlPts>=0?"+":"") + DoubleToString(pnlPts,0) + " pts\n" +
      "💰 P&L ($)   : " + TG_MoneyStr(pnlMoney, cur) + "\n" +
      "💼 Balance   : " + DoubleToString(bal, 2) + " " + cur + "\n" +
      "⏱ Time      : " + TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES) + "\n" +
      "━━━━━━━━━━━━━━━━━━";
   TG_Send(msg);
}

void TG_OnStop()
{
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double pnl = CalcDailyClosedPnL();
   int w=0,l=0; GetDayStats(w,l);
   string msg =
      "⏹ <b> BUY ONLY — STOPPED</b>\n" +
      "━━━━━━━━━━━━━━━━━━\n" +
      "💰 Day PnL : " + TG_MoneyStr(pnl, cur) + "\n" +
      "🏆 Today   : " + IntegerToString(w) + "W / " + IntegerToString(l) + "L\n" +
      "💼 Balance : " + DoubleToString(bal, 2) + " " + cur + "\n" +
      "⏱ Time    : " + TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES) + "\n" +
      "━━━━━━━━━━━━━━━━━━";
   TG_Send(msg);
}

//====================================================================
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   fastHandle   = iMA(_Symbol, PERIOD_CURRENT, FastLen,   0, MODE_SMA, PRICE_CLOSE);
   slowHandle   = iMA(_Symbol, PERIOD_CURRENT, SlowLen,   0, MODE_EMA, PRICE_CLOSE);
   atrHandle    = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);

   if(fastHandle==INVALID_HANDLE || slowHandle==INVALID_HANDLE ||
      atrHandle==INVALID_HANDLE)
   { Print("ERROR: Cannot create indicator handles!"); return(INIT_FAILED); }

   ResetState();
   InitDayTracking();
   RecoverState();

   Print(" BUY ONLY | ", _Symbol, " | ", EA_TF_TAG, " | Magic:", MagicNumber);
   TG_OnStart();
   return(INIT_SUCCEEDED);
}

//====================================================================
void OnDeinit(const int reason)
{
   TG_OnStop();
   if(fastHandle   !=INVALID_HANDLE) IndicatorRelease(fastHandle);
   if(slowHandle   !=INVALID_HANDLE) IndicatorRelease(slowHandle);
   if(atrHandle    !=INVALID_HANDLE) IndicatorRelease(atrHandle);
   ObjectsDeleteAll(0, "GPB_H4_");
}

//====================================================================
void OnTick()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   SyncState();

   if(gTrade.active)
      MonitorTrade(bid, ask);

   if(UseSessionFilter && !IsInSession()) return;

   if(EntryMode == "CLOSE_SIGNAL")
      ProcessCloseSignalMode(bid);
   else
      ProcessOpenNextBarMode(bid);
}

//====================================================================
void ProcessCloseSignalMode(double bid)
{
   double fastMA[], slowMA[];
   ArraySetAsSeries(fastMA, true);
   ArraySetAsSeries(slowMA, true);
   if(CopyBuffer(fastHandle,0,0,3,fastMA)<3) return;
   if(CopyBuffer(slowHandle,0,0,3,slowMA)<3) return;

   datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);

   bool buySignal = (fastMA[1]<=slowMA[1]) && (fastMA[0]>slowMA[0]);

   if(buySignal)
   {
      bool fired = HasFiredThisBar(currentBar);
      Print("[SIGNAL] BUY detected | Active=",gTrade.active," Dir=",gTrade.dir," Fired=",fired);
      if(!fired) HandleBuy();
      else Print("[SIGNAL] BUY skipped — already fired this bar");
   }

   if(currentBar != lastBarTime)
   {
      lastBarTime = currentBar;
      CheckNewDay();
      if(DrawMAOnChart) DrawMALines(MADrawBars);
   }

   if(gTrade.active) ExtendBoxes();
   if(ShowInfo) DrawInfoPanel(fastMA[1], slowMA[1], buySignal, bid);
}

//====================================================================
void ProcessOpenNextBarMode(double bid)
{
   double fastMA[], slowMA[];
   ArraySetAsSeries(fastMA, true);
   ArraySetAsSeries(slowMA, true);

   datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);

   if(currentBar == lastBarTime)
   {
      if(ShowInfo)
      {
         if(CopyBuffer(fastHandle,0,0,2,fastMA)<2) return;
         if(CopyBuffer(slowHandle,0,0,2,slowMA)<2) return;
         DrawInfoPanel(fastMA[1], slowMA[1], false, bid);
      }
      return;
   }

   lastBarTime = currentBar;
   CheckNewDay();

   if(CopyBuffer(fastHandle,0,0,3,fastMA)<3) return;
   if(CopyBuffer(slowHandle,0,0,3,slowMA)<3) return;

   bool buySignal = (fastMA[2]<=slowMA[2]) && (fastMA[1]>slowMA[1]);

   if(buySignal)
   {
      Print("[SIGNAL] BUY | Active=",gTrade.active," Dir=",gTrade.dir);
      HandleBuy();
   }

   if(DrawMAOnChart) DrawMALines(MADrawBars);
   if(gTrade.active) ExtendBoxes();
   if(ShowInfo) DrawInfoPanel(fastMA[1], slowMA[1], buySignal, bid);
}

//====================================================================
void SyncState()
{
   if(!gTrade.active) return;
   bool p1 = (gTrade.ticket>0 && PositionSelectByTicket(gTrade.ticket));
   bool p2 = (gTrade.ticket2>0 && PositionSelectByTicket(gTrade.ticket2));
   if(!p1 && !p2)
   {
      Print("SyncState: position(s) closed externally");
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double pnlPts = (bid-gTrade.entry)/_Point;
      double pnlMoney = 0.0;
      if(HistorySelect(TimeCurrent()-86400, TimeCurrent()))
         for(int t=0;t<2;t++)
         {
            ulong pid = (t==0)?gTrade.ticket:gTrade.ticket2;
            if(pid==0) continue;
            for(int i=HistoryDealsTotal()-1; i>=0; i--)
            {
               ulong dt = HistoryDealGetTicket(i);
               if((ulong)HistoryDealGetInteger(dt,DEAL_POSITION_ID)!=pid) continue;
               if((int)HistoryDealGetInteger(dt,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
               pnlMoney+=HistoryDealGetDouble(dt,DEAL_PROFIT)+HistoryDealGetDouble(dt,DEAL_COMMISSION)+HistoryDealGetDouble(dt,DEAL_SWAP);
               break;
            }
         }
      TG_OnClose("CLOSED EXTERNALLY", gTrade.entry, bid, pnlMoney, pnlPts, gTrade.ticket);
      ResetState(); DeleteAllBoxObjects();
      return;
   }
   if(!p1 && p2) { gTrade.ticket = gTrade.ticket2; gTrade.ticket2 = 0; }
   else if(p1 && !p2 && gTrade.ticket2>0) { gTrade.ticket2 = 0; }
}

//====================================================================
void RecoverState()
{
   ulong t1=0, t2=0;
   int n=0;
   for(int i=0; i<PositionsTotal(); i++)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol()!=_Symbol) continue;
      if((long)posInfo.Magic()!=(long)MagicNumber) continue;
      if((int)posInfo.PositionType()!=POSITION_TYPE_BUY) continue;
      ulong t=posInfo.Ticket();
      if(n==0) { t1=t; n++; }
      else if(n==1) { t2=t; n++; break; }
   }
   if(n==0) return;
   if(!posInfo.SelectByTicket(t1)) return;
   gTrade.ticket  = t1;
   gTrade.ticket2 = (n>=2)?t2:0;
   gTrade.dir     = (int)POSITION_TYPE_BUY;
   gTrade.entry   = posInfo.PriceOpen();
   gTrade.active  = true;
   gTrade.breakevenDone = false;
   gTrade.sl=AddExtraToSlPrice(GetSwingLow(LookbackSwing)); gTrade.tp=gTrade.entry+(gTrade.entry-gTrade.sl)*RR;
   Print("RecoverState: ticket=",gTrade.ticket," ticket2=",gTrade.ticket2," Dir=BUY");
   DrawBoxes(gTrade.entry, gTrade.sl, gTrade.tp);
}

//====================================================================
void ApplyBuyBreakevenLock(double progress)
{
   double totalDist = MathAbs(gTrade.tp - gTrade.entry);
   double lockDist = (BreakevenLockPct/100.0)*totalDist;
   double newSL    = (BreakevenLockPct<=0.0) ? gTrade.entry : (gTrade.entry + lockDist);
   if(BreakevenLockPct>0.0)
   {
      if(newSL >= gTrade.tp) newSL = gTrade.tp - _Point;
      if(newSL <= gTrade.entry) newSL = gTrade.entry + _Point;
   }
   long minDistPts=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minMove=(minDistPts>0)?(double)minDistPts*_Point:_Point;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= newSL) newSL = bid + minMove;
   gTrade.sl = NormalizeDouble(newSL, _Digits);
   gTrade.breakevenDone=true;
   UpdateSLBox();
   Print("BE+LOCK @ ",DoubleToString(progress,1),"%→TP | SL=",gTrade.sl);
   TG_OnBreakeven(gTrade.sl, gTrade.entry, progress);
}

//====================================================================
void MonitorTrade(double bid, double ask)
{
   if(gTrade.ticket2>0 && !PositionSelectByTicket(gTrade.ticket2)) gTrade.ticket2=0;

   if(!gTrade.breakevenDone)
   {
      double totalDist = MathAbs(gTrade.tp - gTrade.entry);
      double traveled  = (bid - gTrade.entry);
      double progress  = (totalDist>0.0) ? (traveled/totalDist*100.0) : 0.0;
      if(progress >= BreakevenTriggerPct)
      {
         if(gTrade.ticket2>0 && PositionSelectByTicket(gTrade.ticket2))
         {
            ulong tkClose=gTrade.ticket2;
            if(trade.PositionClose(tkClose))
            {
               Print("PARTIAL: closed 2nd leg #",tkClose," @ ",DoubleToString(progress,1),"%→TP");
               gTrade.ticket2=0;
               ApplyBuyBreakevenLock(progress);
            }
            return;
         }
         ApplyBuyBreakevenLock(progress);
      }
   }

   bool hitSL = (bid<=gTrade.sl);
   bool hitTP = (bid>=gTrade.tp);

   if(hitSL || hitTP)
   {
      string lbl    = hitTP ? "TP HIT" : (gTrade.breakevenDone ? "BE HIT" : "SL HIT");
      color  lclr   = hitTP ? clrLime  : (gTrade.breakevenDone ? clrGold : clrRed);
      double cprice = hitTP ? gTrade.tp : gTrade.sl;
      double pnlPts = (cprice-gTrade.entry)/_Point;

      ulong legs[2]; int nLegs=0;
      if(gTrade.ticket>0 && PositionSelectByTicket(gTrade.ticket))  legs[nLegs++]=gTrade.ticket;
      if(gTrade.ticket2>0 && PositionSelectByTicket(gTrade.ticket2)) legs[nLegs++]=gTrade.ticket2;
      if(nLegs==0) { ResetState(); DeleteAllBoxObjects(); return; }

      double snapEntry=gTrade.entry;
      bool anyClosed=false;
      for(int li=0;li<nLegs;li++)
         if(trade.PositionClose(legs[li])) anyClosed=true;
      if(!anyClosed) { Print("Close failed: ",trade.ResultRetcodeDescription()); return; }

      DrawHitLabel(lbl, cprice, lclr);
      double pnlMoney=0.0;
      Sleep(200);
      if(HistorySelect(TimeCurrent()-86400,TimeCurrent()))
         for(int li=0;li<nLegs;li++)
            for(int i=HistoryDealsTotal()-1;i>=0;i--)
            {
               ulong dt=HistoryDealGetTicket(i);
               if((ulong)HistoryDealGetInteger(dt,DEAL_POSITION_ID)!=legs[li]) continue;
               if((int)HistoryDealGetInteger(dt,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
               pnlMoney+=HistoryDealGetDouble(dt,DEAL_PROFIT)+HistoryDealGetDouble(dt,DEAL_COMMISSION)+HistoryDealGetDouble(dt,DEAL_SWAP);
               break;
            }
      TG_OnClose(lbl, snapEntry, cprice, pnlMoney, pnlPts, legs[0]);
      if(pnlMoney>=0) dayWins++;
      else { dayLosses++; if(UseCooldown) lastLossBarTime=iTime(_Symbol,PERIOD_CURRENT,0); }

      ResetState(); DeleteAllBoxObjects();
   }
}

//====================================================================
string CheckFiltersBuy()
{
   if(UseATRFilter)
   {
      double atr[]; ArraySetAsSeries(atr,true);
      if(CopyBuffer(atrHandle,0,0,ATRPeriod+1,atr)<ATRPeriod+1) return "ATR data unavailable";
      double curATR=atr[1], sumATR=0.0;
      for(int i=1;i<=ATRPeriod;i++) sumATR+=atr[i];
      if(curATR < (sumATR/ATRPeriod)*ATRMinMultiplier)
         return "Low volatility (ATR "+DoubleToString(curATR/_Point,0)+" pts)";
   }

   if(UseAngleFilter)
   {
      double slowMA[]; ArraySetAsSeries(slowMA,true);
      if(CopyBuffer(slowHandle,0,0,3,slowMA)<3) return "SlowMA data unavailable";
      double slope=(slowMA[1]-slowMA[2])/_Point;
      if(slope<MinSlopePoints) return "MA slope too flat for BUY ("+DoubleToString(slope,1)+" pts)";
   }

   if(UseCooldown && lastLossBarTime>0)
   {
      int barsSince=iBarShift(_Symbol,PERIOD_CURRENT,lastLossBarTime,false);
      if(barsSince<CooldownBars) return "Cooldown active ("+IntegerToString(CooldownBars-barsSince)+" bars left)";
   }

   if(MinRiskPoints>0)
   {
      double entry=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double sl=AddExtraToSlPrice(GetSwingLow(LookbackSwing));
      double riskPts=MathAbs(entry-sl)/_Point;
      if(riskPts<MinRiskPoints) return "Risk too small ("+DoubleToString(riskPts,0)+" pts < min "+DoubleToString(MinRiskPoints,0)+")";
   }

   return "";
}

//====================================================================
bool IsDailyLossLimitReached()
{
   if(!UseDailyLossLimit) return false;
   double closed = CalcDailyClosedPnL();
   double fl = GetFloatingPnLBoth();
   double totalDay = closed + fl;
   return (totalDay <= -DailyLossLimit);
}

//====================================================================
void HandleBuy()
{
   bool justClosedOpposite = false;
   Print("[BUY] HandleBuy() | active=",gTrade.active," dir=",gTrade.dir," ticket=",gTrade.ticket);

   if(CloseOnOpposite && gTrade.active && gTrade.dir==POSITION_TYPE_SELL)
   {
      ulong old=gTrade.ticket;
      if(!trade.PositionClose(old))
      { Print("[BUY] Close opposite SELL FAILED: ",trade.ResultRetcodeDescription()); return; }
      Print("[BUY] Closed opposite SELL #",old," OK");
      ResetState(); DeleteAllBoxObjects();
      lastBuyFireBar=0;
      justClosedOpposite=true;
   }

   if(gTrade.active) { Print("[BUY] BLOCKED — gTrade.active still true"); return; }
   int pc=CountPositions();
   if(!justClosedOpposite && pc>0) { Print("[BUY] BLOCKED — CountPositions=",pc); return; }

   if(IsDailyLossLimitReached())
   { Print("[BUY] BLOCKED — daily loss limit (",DoubleToString(DailyLossLimit,2)," ",AccountInfoString(ACCOUNT_CURRENCY),")"); return; }

   if(!justClosedOpposite || !SkipFiltersOnReverse)
   {
      string fr=CheckFiltersBuy();
      if(fr!="") { Print("[BUY] BLOCKED by filter: ",fr); return; }
      Print("[BUY] Filters passed");
   }
   else Print("[BUY] Reverse — filters skipped");

   double entry=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double sl=GetSwingLow(LookbackSwing);
   double risk=entry-sl;
   double minD=GetMinSLDistance();
   if(risk<minD) { sl=entry-minD; risk=minD; Print("[BUY] SL expanded to ",DoubleToString(sl,2)); }
   sl=AddExtraToSlPrice(sl);
   risk=entry-sl;

   Print("[BUY] entry=",DoubleToString(entry,2)," sl=",DoubleToString(sl,2)," risk=",DoubleToString(risk/_Point,1)," pts");
   if(sl>=entry) { Print("[BUY] BLOCKED — SL>=Entry"); return; }
   if(risk<_Point*MinRiskPoints) { Print("[BUY] BLOCKED — risk too small"); return; }
   if(risk<_Point*5) { Print("[BUY] BLOCKED — spread risk"); return; }

   double tp=entry+risk*RR;
   double lotTotal=UseRiskBasedLot ? CalcLotByRisk(risk) : CalcLotByBalance();

   Print("[BUY] Placing | lot=",lotTotal," tp=",DoubleToString(tp,2));
   TG_OnSignal((int)POSITION_TYPE_BUY, entry, sl, tp, lotTotal);

   if(!trade.Buy(lotTotal,_Symbol,0,0,0,OrderCommentWithTf("BUY")))
   { Print("[BUY] ORDER FAILED: ",trade.ResultRetcodeDescription());
     TG_Send("⚠️ <b>BUY FAILED</b>\n"+_Symbol+"\n"+trade.ResultRetcodeDescription()); return; }

   ulong ticket=trade.ResultDeal();
   if(ticket==0) ticket=GetTicketByDeal();
   if(ticket==0) { Print("[BUY] Cannot get ticket"); return; }

   double fp=trade.ResultPrice(); if(fp>0) entry=fp;
   risk=entry-sl; if(risk<_Point*5) risk=_Point*5;
   tp=entry+risk*RR;

   gTrade.ticket=ticket; gTrade.ticket2=0; gTrade.dir=(int)POSITION_TYPE_BUY; gTrade.entry=entry;
   gTrade.sl=sl; gTrade.tp=tp; gTrade.active=true; gTrade.breakevenDone=false;

   DrawBoxes(entry,sl,tp);
   Print("[BUY] OPENED ✅ | Fill=",entry," SL=",sl," TP=",tp," Lot=",lotTotal," Ticket=",ticket);
   MarkFiredThisBar(iTime(_Symbol,PERIOD_CURRENT,0));
   TG_OnOpen((int)POSITION_TYPE_BUY,entry,sl,tp,lotTotal,ticket);
}

//====================================================================
ulong GetTicketByDeal()
{
   ulong dealTicket=trade.ResultDeal();
   if(dealTicket>0 && HistoryDealSelect(dealTicket))
   {
      ulong posTicket=(ulong)HistoryDealGetInteger(dealTicket,DEAL_POSITION_ID);
      if(posTicket>0 && PositionSelectByTicket(posTicket)) return posTicket;
   }
   ulong newest=0;
   for(int i=0;i<PositionsTotal();i++)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol()!=_Symbol) continue;
      if((long)posInfo.Magic()!=(long)MagicNumber) continue;
      if(posInfo.Ticket()>newest) newest=posInfo.Ticket();
   }
   return newest;
}

int CountPositions()
{
   int count=0;
   for(int i=0;i<PositionsTotal();i++)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol()!=_Symbol) continue;
      if((long)posInfo.Magic()!=(long)MagicNumber) continue;
      count++;
   }
   return count;
}

void InitDayTracking()
{
   dayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);
   dayWins=0; dayLosses=0;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   dayStartTime=StructToTime(dt);
}

void CheckNewDay()
{
   MqlDateTime now,dst;
   TimeToStruct(TimeCurrent(),now); TimeToStruct(dayStartTime,dst);
   if(now.day!=dst.day||now.mon!=dst.mon||now.year!=dst.year)
   { Print("New day — resetting stats"); InitDayTracking(); }
}

double CalcDailyClosedPnL()
{
   double pnl=0.0;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   dt.hour=0;dt.min=0;dt.sec=0;
   datetime todayStart=StructToTime(dt);
   if(!HistorySelect(todayStart,TimeCurrent())) return 0.0;
   int deals=HistoryDealsTotal();
   for(int i=0;i<deals;i++)
   {
      ulong dT=HistoryDealGetTicket(i); if(dT==0) continue;
      if(HistoryDealGetString(dT,DEAL_SYMBOL)!=_Symbol) continue;
      if((long)HistoryDealGetInteger(dT,DEAL_MAGIC)!=(long)MagicNumber) continue;
      if((int)HistoryDealGetInteger(dT,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      pnl+=HistoryDealGetDouble(dT,DEAL_PROFIT)+HistoryDealGetDouble(dT,DEAL_COMMISSION)+HistoryDealGetDouble(dT,DEAL_SWAP);
   }
   return pnl;
}

void GetDayStats(int &wins, int &losses)
{
   wins=0; losses=0;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   dt.hour=0;dt.min=0;dt.sec=0;
   datetime todayStart=StructToTime(dt);
   if(!HistorySelect(todayStart,TimeCurrent())) return;
   int deals=HistoryDealsTotal();
   for(int i=0;i<deals;i++)
   {
      ulong dT=HistoryDealGetTicket(i); if(dT==0) continue;
      if(HistoryDealGetString(dT,DEAL_SYMBOL)!=_Symbol) continue;
      if((long)HistoryDealGetInteger(dT,DEAL_MAGIC)!=(long)MagicNumber) continue;
      if((int)HistoryDealGetInteger(dT,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      double p=HistoryDealGetDouble(dT,DEAL_PROFIT);
      if(p>=0) wins++; else losses++;
   }
}

void ResetState()
{
   gTrade.ticket=0; gTrade.ticket2=0; gTrade.dir=NO_TRADE; gTrade.entry=0;
   gTrade.sl=0; gTrade.tp=0; gTrade.active=false; gTrade.breakevenDone=false;
}

bool HasFiredThisBar(datetime barTime)
{
   return (lastBuyFireBar==barTime);
}
void MarkFiredThisBar(datetime barTime)
{
   lastBuyFireBar=barTime;
}

//====================================================================
void DrawBoxes(double entry, double sl, double tp)
{
   DeleteAllBoxObjects();
   datetime t1=iTime(_Symbol,PERIOD_CURRENT,1);
   datetime t2=iTime(_Symbol,PERIOD_CURRENT,0)+(datetime)PeriodSeconds(PERIOD_CURRENT)*BoxExtendBars;

   ObjectCreate(0,"GPB_H4_EntryLine",OBJ_TREND,0,t1,entry,t2,entry);
   ObjectSetInteger(0,"GPB_H4_EntryLine",OBJPROP_COLOR,ColorEntryLine);
   ObjectSetInteger(0,"GPB_H4_EntryLine",OBJPROP_WIDTH,2);
   ObjectSetInteger(0,"GPB_H4_EntryLine",OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,"GPB_H4_EntryLine",OBJPROP_RAY_RIGHT,false);
   ObjectSetInteger(0,"GPB_H4_EntryLine",OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,"GPB_H4_EntryLine",OBJPROP_HIDDEN,true);

   double slTop=entry, slBot=sl;
   ObjectCreate(0,"GPB_H4_SLBox",OBJ_RECTANGLE,0,t1,slTop,t2,slBot);
   ObjectSetInteger(0,"GPB_H4_SLBox",OBJPROP_COLOR,ColorSLBox);
   ObjectSetInteger(0,"GPB_H4_SLBox",OBJPROP_FILL,true);
   ObjectSetInteger(0,"GPB_H4_SLBox",OBJPROP_BACK,true);
   ObjectSetInteger(0,"GPB_H4_SLBox",OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,"GPB_H4_SLBox",OBJPROP_HIDDEN,true);

   double tpTop=tp, tpBot=entry;
   ObjectCreate(0,"GPB_H4_TPBox",OBJ_RECTANGLE,0,t1,tpTop,t2,tpBot);
   ObjectSetInteger(0,"GPB_H4_TPBox",OBJPROP_COLOR,ColorTPBox);
   ObjectSetInteger(0,"GPB_H4_TPBox",OBJPROP_FILL,true);
   ObjectSetInteger(0,"GPB_H4_TPBox",OBJPROP_BACK,true);
   ObjectSetInteger(0,"GPB_H4_TPBox",OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,"GPB_H4_TPBox",OBJPROP_HIDDEN,true);

   string dirTxt="▲ BUY";
   color  dirClr=clrLime;
   DrawPriceLabel("GPB_H4_LabelDir",dirTxt,t1,entry,dirClr);
   DrawPriceLabel("GPB_H4_LabelEN","Entry: "+DoubleToString(entry,_Digits),t2,entry,ColorEntryLine);
   DrawPriceLabel("GPB_H4_LabelSL","SL: "+DoubleToString(sl,_Digits),t2,sl,ColorSLBox);
   DrawPriceLabel("GPB_H4_LabelTP","TP: "+DoubleToString(tp,_Digits),t2,tp,ColorTPBox);
   ChartRedraw(0);
}

void ExtendBoxes()
{
   datetime t2=iTime(_Symbol,PERIOD_CURRENT,0)+(datetime)PeriodSeconds(PERIOD_CURRENT)*BoxExtendBars;
   string objs[]={"GPB_H4_EntryLine","GPB_H4_SLBox","GPB_H4_TPBox","GPB_H4_LabelEN","GPB_H4_LabelSL","GPB_H4_LabelTP","GPB_H4_LabelDir","GPB_H4_BELine"};
   for(int i=0;i<ArraySize(objs);i++)
      if(ObjectFind(0,objs[i])>=0)
         ObjectSetInteger(0,objs[i],OBJPROP_TIME,1,t2);
}

void DrawMALines(int barsBack)
{
   for(int i=0;i<barsBack;i++)
   {
      string fn="GPB_H4_FastMA_"+IntegerToString(i);
      string sn="GPB_H4_SlowMA_"+IntegerToString(i);
      if(ObjectFind(0,fn)>=0) ObjectDelete(0,fn);
      if(ObjectFind(0,sn)>=0) ObjectDelete(0,sn);
   }
   double fastMA[],slowMA[];
   ArraySetAsSeries(fastMA,true); ArraySetAsSeries(slowMA,true);
   int copied=barsBack+1;
   if(CopyBuffer(fastHandle,0,0,copied,fastMA)<copied) return;
   if(CopyBuffer(slowHandle,0,0,copied,slowMA)<copied) return;
   for(int i=0;i<barsBack;i++)
   {
      datetime t1=iTime(_Symbol,PERIOD_CURRENT,i+1), t2=iTime(_Symbol,PERIOD_CURRENT,i);
      if(t1==0||t2==0) continue;
      string fn="GPB_H4_FastMA_"+IntegerToString(i);
      ObjectCreate(0,fn,OBJ_TREND,0,t1,fastMA[i+1],t2,fastMA[i]);
      ObjectSetInteger(0,fn,OBJPROP_COLOR,clrDodgerBlue); ObjectSetInteger(0,fn,OBJPROP_WIDTH,2);
      ObjectSetInteger(0,fn,OBJPROP_STYLE,STYLE_SOLID);   ObjectSetInteger(0,fn,OBJPROP_RAY_RIGHT,false);
      ObjectSetInteger(0,fn,OBJPROP_SELECTABLE,false);    ObjectSetInteger(0,fn,OBJPROP_BACK,true);
      ObjectSetInteger(0,fn,OBJPROP_HIDDEN,true);
      string sn="GPB_H4_SlowMA_"+IntegerToString(i);
      ObjectCreate(0,sn,OBJ_TREND,0,t1,slowMA[i+1],t2,slowMA[i]);
      ObjectSetInteger(0,sn,OBJPROP_COLOR,clrOrangeRed); ObjectSetInteger(0,sn,OBJPROP_WIDTH,2);
      ObjectSetInteger(0,sn,OBJPROP_STYLE,STYLE_SOLID);  ObjectSetInteger(0,sn,OBJPROP_RAY_RIGHT,false);
      ObjectSetInteger(0,sn,OBJPROP_SELECTABLE,false);   ObjectSetInteger(0,sn,OBJPROP_BACK,true);
      ObjectSetInteger(0,sn,OBJPROP_HIDDEN,true);
   }
   ChartRedraw(0);
}

void UpdateSLBox()
{
   double slPrice=gTrade.sl;
   ObjectSetDouble(0,"GPB_H4_SLBox",OBJPROP_PRICE,0,slPrice); ObjectSetDouble(0,"GPB_H4_SLBox",OBJPROP_PRICE,1,slPrice);
   ObjectSetString(0,"GPB_H4_LabelSL",OBJPROP_TEXT,"BE+: "+DoubleToString(slPrice,_Digits));
   ObjectSetInteger(0,"GPB_H4_LabelSL",OBJPROP_COLOR,clrGold);
   ObjectSetDouble(0,"GPB_H4_LabelSL",OBJPROP_PRICE,slPrice);
   datetime t1=iTime(_Symbol,PERIOD_CURRENT,1);
   datetime t2=iTime(_Symbol,PERIOD_CURRENT,0)+(datetime)PeriodSeconds(PERIOD_CURRENT)*BoxExtendBars;
   if(ObjectFind(0,"GPB_H4_BELine")<0) ObjectCreate(0,"GPB_H4_BELine",OBJ_TREND,0,t1,slPrice,t2,slPrice);
   ObjectSetDouble(0,"GPB_H4_BELine",OBJPROP_PRICE,0,slPrice); ObjectSetDouble(0,"GPB_H4_BELine",OBJPROP_PRICE,1,slPrice);
   ObjectSetInteger(0,"GPB_H4_BELine",OBJPROP_COLOR,clrGold); ObjectSetInteger(0,"GPB_H4_BELine",OBJPROP_WIDTH,2);
   ObjectSetInteger(0,"GPB_H4_BELine",OBJPROP_STYLE,STYLE_DASH); ObjectSetInteger(0,"GPB_H4_BELine",OBJPROP_RAY_RIGHT,false);
   ObjectSetInteger(0,"GPB_H4_BELine",OBJPROP_SELECTABLE,false); ObjectSetInteger(0,"GPB_H4_BELine",OBJPROP_HIDDEN,true);
   ChartRedraw(0);
}

void DeleteAllBoxObjects()
{
   string objs[]={"GPB_H4_EntryLine","GPB_H4_SLBox","GPB_H4_TPBox","GPB_H4_LabelEN","GPB_H4_LabelSL","GPB_H4_LabelTP","GPB_H4_LabelDir","GPB_H4_BELine"};
   for(int i=0;i<ArraySize(objs);i++) if(ObjectFind(0,objs[i])>=0) ObjectDelete(0,objs[i]);
   ChartRedraw(0);
}

void DrawPriceLabel(string name, string txt, datetime t, double price, color clr)
{
   if(ObjectFind(0,name)>=0) ObjectDelete(0,name);
   ObjectCreate(0,name,OBJ_TEXT,0,t,price);
   ObjectSetString(0,name,OBJPROP_TEXT,txt); ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9); ObjectSetString(0,name,OBJPROP_FONT,"Arial Bold");
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false); ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
}

void DrawHitLabel(string txt, double price, color clr)
{
   string name="GPB_H4_Hit_"+IntegerToString(GetTickCount());
   ObjectCreate(0,name,OBJ_TEXT,0,iTime(_Symbol,PERIOD_CURRENT,0),price);
   ObjectSetString(0,name,OBJPROP_TEXT,">>> "+txt+" <<<"); ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,11); ObjectSetString(0,name,OBJPROP_FONT,"Arial Bold");
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
}

//====================================================================
double GetMinSLDistance()
{
   double atr[]; ArraySetAsSeries(atr,true);
   double atrMin=_Point*MinRiskPoints;
   if(atrHandle!=INVALID_HANDLE && CopyBuffer(atrHandle,0,1,1,atr)==1 && atr[0]>0)
      atrMin=MathMax(atrMin, atr[0]*0.5);
   return atrMin;
}

double GetSwingLow(int lookback)
{
   for(int i=2;i<=lookback-1;i++)
   {
      double cur=iLow(_Symbol,PERIOD_CURRENT,i);
      double prev=iLow(_Symbol,PERIOD_CURRENT,i+1);
      double next=iLow(_Symbol,PERIOD_CURRENT,i-1);
      if(cur<prev && cur<next) return cur;
   }
   double v=DBL_MAX;
   for(int i=1;i<=lookback;i++) { double l=iLow(_Symbol,PERIOD_CURRENT,i); if(l<v) v=l; }
   return v;
}

double GetSwingHigh(int lookback)
{
   for(int i=2;i<=lookback-1;i++)
   {
      double cur=iHigh(_Symbol,PERIOD_CURRENT,i);
      double prev=iHigh(_Symbol,PERIOD_CURRENT,i+1);
      double next=iHigh(_Symbol,PERIOD_CURRENT,i-1);
      if(cur>prev && cur>next) return cur;
   }
   double v=0.0;
   for(int i=1;i<=lookback;i++) { double h=iHigh(_Symbol,PERIOD_CURRENT,i); if(h>v) v=h; }
   return v;
}

double CalcLotByBalance()
{
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double lotStep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(BalanceLotStep<=0.0 || LotPerBalanceStep<=0.0) return minLot;

   int steps=(int)MathFloor(balance/BalanceLotStep);
   if(steps<1) steps=1;
   double lot=(double)steps*LotPerBalanceStep;

   lot=MathFloor(lot/lotStep)*lotStep;
   lot=MathMax(minLot,MathMin(lot,MathMin(maxLot,MaxLotSize)));
   return NormalizeDouble(lot,2);
}

double CalcLotByRisk(double riskPoints)
{
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt=balance*RiskPercent/100.0;
   double tickVal=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSz=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double lotStep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(tickSz<=0.0||tickVal<=0.0) return minLot;
   double lot=riskAmt/((riskPoints/tickSz)*tickVal);
   lot=MathFloor(lot/lotStep)*lotStep;
   lot=MathMax(minLot,MathMin(lot,MathMin(maxLot,MaxLotSize)));
   return NormalizeDouble(lot,2);
}

bool IsInSession()
{
   MqlDateTime dt; TimeToStruct(TimeGMT(),dt);
   return(dt.hour>=SessionStartHour && dt.hour<SessionEndHour);
}

//====================================================================
string DashboardSymbolPretty()
{
   if(StringFind(_Symbol,"XAU")>=0 || StringFind(_Symbol,"GOLD")>=0)
      return "XAU/USD";
   return _Symbol;
}

string DashboardSubtitleBuy()
{
   return DashboardSymbolPretty()+"     ·     Auto Trade     ·     BUY     ·     "+ChartTfShort();
}

//====================================================================
void DrawInfoPanel(double fast, double slow, bool buySignal, double price)
{
   string obsolete[]={
      "GPB_H4_DIR","GPB_H4_H1","GPB_H4_A1","GPB_H4_A2","GPB_H4_H2","GPB_H4_D0","GPB_H4_D1","GPB_H4_D2","GPB_H4_D3",
      "GPB_H4_H3","GPB_H4_S1","GPB_H4_S2","GPB_H4","GPB_H4_P2","GPB_H4_P3","GPB_H4_P4","GPB_H4_P5",
      "GPB_DIR","GPB_H1","GPB_A1","GPB_A2","GPB_H2","GPB_D0","GPB_D1","GPB_D2","GPB_D3",
      "GPB_H3","GPB_S1","GPB_S2","GPB_H4","GPB_P2","GPB_P3","GPB_P4","GPB_P5"
   };
   for(int oi=0;oi<ArraySize(obsolete);oi++)
      if(ObjectFind(0,obsolete[oi])>=0) ObjectDelete(0,obsolete[oi]);

   string currency=AccountInfoString(ACCOUNT_CURRENCY);
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyPnL=CalcDailyClosedPnL();
   double floatMoney=0.0;
   if(gTrade.active) floatMoney=GetFloatingPnLBoth();
   double totalDayPnL=dailyPnL+floatMoney;

   string sigText=buySignal?"▲  BUY":"○  WAIT";
   color  sigClr=buySignal?clrLime:clrGray;

   int x=12,y=10,dyTitle=22,dySub=15,dy=15;

   GPB_H4_Label("GPB_H4_H0","TVH-Smile",x,y,clrDeepSkyBlue,12,true); y+=dyTitle;
   GPB_H4_Label("GPB_H4_TS",DashboardSubtitleBuy(),x,y,clrSilver,9,false); y+=dySub;
   GPB_H4_Label("GPB_H4_S0","Signal     "+sigText,x,y,sigClr,10,true); y+=dy;
   GPB_H4_Label("GPB_H4_A0","Balance  "+DoubleToString(balance,2)+" "+currency+
      "     ·     Today  "+(totalDayPnL>=0?"+":"")+DoubleToString(totalDayPnL,2)+" "+currency,
      x,y,(totalDayPnL>=0?clrWhite:clrTomato),9,false); y+=dy;

   if(gTrade.active)
   {
      if(ObjectFind(0,"GPB_H4_P0")>=0) ObjectDelete(0,"GPB_H4_P0");
      double pnlPts=(price-gTrade.entry)/_Point;
      string posLine=(gTrade.ticket2>0?"2 legs · ":"")+
         "Entry "+DoubleToString(gTrade.entry,_Digits)+
         "     ·     SL "+DoubleToString(gTrade.sl,_Digits)+
         "     ·     TP "+DoubleToString(gTrade.tp,_Digits)+
         "     ·     P/L "+(floatMoney>=0?"+":"")+DoubleToString(floatMoney,2)+" "+
         currency+"  ("+(pnlPts>=0?"+":"")+DoubleToString(pnlPts,0)+" pt)";
      GPB_H4_Label("GPB_H4_P1",posLine,x,y,(pnlPts>=0?clrLime:clrTomato),9,false); y+=dy;
   }
   else
   {
      if(ObjectFind(0,"GPB_H4_P1")>=0) ObjectDelete(0,"GPB_H4_P1");
      GPB_H4_Label("GPB_H4_P0","○  No open position",x,y,clrDarkGray,9,false); y+=dy;
   }

   string maCompact="SMA"+IntegerToString(FastLen)+"/EMA"+IntegerToString(SlowLen)+": "+
      DoubleToString(fast,_Digits)+"/"+DoubleToString(slow,_Digits);
   string foot=UseRiskBasedLot
      ? ("RR 1:"+DoubleToString(RR,1)+"     ·     Risk "+DoubleToString(RiskPercent,1)+"%     ·     "+maCompact)
      : ("RR 1:"+DoubleToString(RR,1)+"     ·     Lot "+DoubleToString(LotPerBalanceStep,2)+"/"+DoubleToString(BalanceLotStep,0)+
         "     ·     "+maCompact);
   color footClr=clrDimGray;
   if(UseDailyLossLimit)
   {
      foot += "     ·     Max loss/day  "+DoubleToString(DailyLossLimit,0)+" "+currency;
      if(totalDayPnL <= -DailyLossLimit) { foot += "     ·     STOP  (no new trades)"; footClr = clrTomato; }
   }
   GPB_H4_Label("GPB_H4_F0",foot,x,y,footClr,8,false);
}

void GPB_H4_Label(string name, string txt, int x, int y, color clr, int sz, bool bold)
{
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_RIGHT_UPPER);
   ObjectSetString(0,name,OBJPROP_TEXT,txt); ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,sz);
   ObjectSetString(0,name,OBJPROP_FONT,bold?"Arial Bold":"Arial");
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false); ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
}
//+------------------------------------------------------------------+
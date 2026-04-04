//+------------------------------------------------------------------+
//|                                               GoldPro_EA.mq5     |
//|     SMA9 x EMA21 | Visual Box | Hidden SL/TP | Breakeven         |
//|     Sell-only — H1 — Magic 203102 | Prefix GPS_H1_*           |
//|     Bản riêng H1: không trùng Magic với các khung/hướng khác   |
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

input ulong  MagicNumber      = 203102; // Giữ khác Magic của EA BUY khi chạy cùng symbol
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

// SELL: mở 2 lệnh. Khi giá đạt BreakevenTriggerPct % đường Entry→TP: đóng 1 lệnh, lệnh còn lại
// dời SL ẩn (BreakevenLockPct % quãng Entry→TP phía dưới entry).
input double BreakevenTriggerPct = 30.0;
input double BreakevenLockPct    = 10.0;

input string EntryMode        = "SELL ONLY"; // OPEN_NEXT_BAR | CLOSE_SIGNAL

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
   ulong  ticket;
   ulong  ticket2;
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

datetime lastSellFireBar = 0;

//====================================================================
// Comment lệnh cố định H1_SELL — Magic riêng; đối tượng chart prefix GPS_H1_
const string EA_TF_TAG = "H1";

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

string TG_Emoji(int dir)     { return "🔴"; }
string TG_DirStr(int dir)    { return "SELL ▼"; }
string TG_PriceStr(double p) { return DoubleToString(p, _Digits); }
string TG_MoneyStr(double v, string cur)
{ return (v >= 0 ? "+" : "") + DoubleToString(v, 2) + " " + cur; }

void TG_OnStart()
{
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   string msg =
      "🤖 <b> SELL ONLY — STARTED</b>\n" +
      "━━━━━━━━━━━━━━━━━━\n" +
      "📊 Symbol    : " + _Symbol + "  " + EnumToString(Period()) + "\n" +
      "🏦 Account   : " + AccountInfoString(ACCOUNT_NAME) + "\n" +
      "💰 Balance   : " + DoubleToString(bal, 2) + " " + cur + "\n" +
      "🎯 Direction : SELL ONLY\n" +
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

void TG_OnOpenTwoSell(double entry, double sl, double tp, double lot1, double lot2, ulong tk1, ulong tk2)
{
   string msg =
      TG_Emoji((int)POSITION_TYPE_SELL) + " <b>2 ORDERS OPENED — SELL</b>\n" +
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
      "⏹ <b> SELL ONLY — STOPPED</b>\n" +
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

   Print(" SELL ONLY | ", _Symbol, " | ", EA_TF_TAG, " | Magic:", MagicNumber);
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
   ObjectsDeleteAll(0, "GPS_H1_");
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

   bool sellSignal = (fastMA[1]>=slowMA[1]) && (fastMA[0]<slowMA[0]);

   if(sellSignal)
   {
      bool fired = HasFiredThisBar(currentBar);
      Print("[SIGNAL] SELL detected | Active=",gTrade.active," Dir=",gTrade.dir," Fired=",fired);
      if(!fired) HandleSell();
      else Print("[SIGNAL] SELL skipped — already fired this bar");
   }

   if(currentBar != lastBarTime)
   {
      lastBarTime = currentBar;
      CheckNewDay();
      if(DrawMAOnChart) DrawMALines(MADrawBars);
   }

   if(gTrade.active) ExtendBoxes();
   if(ShowInfo) DrawInfoPanel(fastMA[1], slowMA[1], sellSignal, bid);
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

   bool sellSignal = (fastMA[2]>=slowMA[2]) && (fastMA[1]<slowMA[1]);

   if(sellSignal)
   {
      Print("[SIGNAL] SELL | Active=",gTrade.active," Dir=",gTrade.dir);
      HandleSell();
   }

   if(DrawMAOnChart) DrawMALines(MADrawBars);
   if(gTrade.active) ExtendBoxes();
   if(ShowInfo) DrawInfoPanel(fastMA[1], slowMA[1], sellSignal, bid);
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
      double pnlPts = (gTrade.entry-bid)/_Point;
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
      if((int)posInfo.PositionType()!=POSITION_TYPE_SELL) continue;
      ulong t=posInfo.Ticket();
      if(n==0) { t1=t; n++; }
      else if(n==1) { t2=t; n++; break; }
   }
   if(n==0) return;
   if(!posInfo.SelectByTicket(t1)) return;
   gTrade.ticket  = t1;
   gTrade.ticket2 = (n>=2)?t2:0;
   gTrade.dir     = (int)POSITION_TYPE_SELL;
   gTrade.entry   = posInfo.PriceOpen();
   gTrade.active  = true;
   gTrade.breakevenDone = false;
   gTrade.sl=AddExtraToSlPrice(GetSwingHigh(LookbackSwing)); gTrade.tp=gTrade.entry-(gTrade.sl-gTrade.entry)*RR;
   Print("RecoverState: ticket=",gTrade.ticket," ticket2=",gTrade.ticket2," Dir=SELL");
   DrawBoxes(gTrade.entry, gTrade.sl, gTrade.tp);
}

//====================================================================
void ApplySellBreakevenLock(double progress)
{
   double totalDist = MathAbs(gTrade.tp - gTrade.entry);
   double lockDist = (BreakevenLockPct/100.0)*totalDist;
   double newSL    = (BreakevenLockPct<=0.0) ? gTrade.entry : (gTrade.entry - lockDist);
   if(BreakevenLockPct>0.0)
   {
      if(newSL <= gTrade.tp) newSL = gTrade.tp + _Point;
      if(newSL >= gTrade.entry) newSL = gTrade.entry - _Point;
   }
   long minDistPts=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minMove=(minDistPts>0)?(double)minDistPts*_Point:_Point;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask >= newSL) newSL = ask - minMove;
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
      double traveled  = (gTrade.entry-ask);
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
               ApplySellBreakevenLock(progress);
            }
            return;
         }
         ApplySellBreakevenLock(progress);
      }
   }

   bool hitSL = (ask>=gTrade.sl);
   bool hitTP = (ask<=gTrade.tp);

   if(hitSL || hitTP)
   {
      string lbl    = hitTP ? "TP HIT" : (gTrade.breakevenDone ? "BE HIT" : "SL HIT");
      color  lclr   = hitTP ? clrLime  : (gTrade.breakevenDone ? clrGold : clrRed);
      double cprice = hitTP ? gTrade.tp : gTrade.sl;
      double pnlPts = (gTrade.entry-cprice)/_Point;

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
string CheckFiltersSell()
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
      if(slope>-MinSlopePoints) return "MA slope too flat for SELL ("+DoubleToString(slope,1)+" pts)";
   }

   if(UseCooldown && lastLossBarTime>0)
   {
      int barsSince=iBarShift(_Symbol,PERIOD_CURRENT,lastLossBarTime,false);
      if(barsSince<CooldownBars) return "Cooldown active ("+IntegerToString(CooldownBars-barsSince)+" bars left)";
   }

   if(MinRiskPoints>0)
   {
      double entry=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double sl=AddExtraToSlPrice(GetSwingHigh(LookbackSwing));
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
void HandleSell()
{
   bool justClosedOpposite = false;
   Print("[SELL] HandleSell() | active=",gTrade.active," dir=",gTrade.dir," ticket=",gTrade.ticket);

   if(CloseOnOpposite && gTrade.active && gTrade.dir==POSITION_TYPE_BUY)
   {
      bool ok=true;
      if(gTrade.ticket>0 && PositionSelectByTicket(gTrade.ticket))
      { if(!trade.PositionClose(gTrade.ticket)) ok=false; }
      if(ok && gTrade.ticket2>0 && PositionSelectByTicket(gTrade.ticket2))
      { if(!trade.PositionClose(gTrade.ticket2)) ok=false; }
      if(!ok)
      { Print("[SELL] Close opposite BUY FAILED: ",trade.ResultRetcodeDescription()); return; }
      Print("[SELL] Closed opposite BUY leg(s) OK");
      ResetState(); DeleteAllBoxObjects();
      lastSellFireBar=0;
      justClosedOpposite=true;
   }

   if(gTrade.active) { Print("[SELL] BLOCKED — gTrade.active still true"); return; }
   int pc=CountPositions();
   if(!justClosedOpposite && pc>0) { Print("[SELL] BLOCKED — CountPositions=",pc); return; }

   if(IsDailyLossLimitReached())
   { Print("[SELL] BLOCKED — daily loss limit (",DoubleToString(DailyLossLimit,2)," ",AccountInfoString(ACCOUNT_CURRENCY),")"); return; }

   if(!justClosedOpposite || !SkipFiltersOnReverse)
   {
      string fr=CheckFiltersSell();
      if(fr!="") { Print("[SELL] BLOCKED by filter: ",fr); return; }
      Print("[SELL] Filters passed");
   }
   else Print("[SELL] Reverse — filters skipped");

   double entry=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double sl=GetSwingHigh(LookbackSwing);
   double risk=sl-entry;
   double minD=GetMinSLDistance();
   if(risk<minD) { sl=entry+minD; risk=minD; Print("[SELL] SL expanded to ",DoubleToString(sl,2)); }
   sl=AddExtraToSlPrice(sl);
   risk=sl-entry;

   Print("[SELL] entry=",DoubleToString(entry,2)," sl=",DoubleToString(sl,2)," risk=",DoubleToString(risk/_Point,1)," pts");
   if(sl<=entry) { Print("[SELL] BLOCKED — SL<=Entry"); return; }
   if(risk<_Point*MinRiskPoints) { Print("[SELL] BLOCKED — risk too small"); return; }
   if(risk<_Point*5) { Print("[SELL] BLOCKED — spread risk"); return; }

   double tp=entry-risk*RR;
   double lotTotal=UseRiskBasedLot ? CalcLotByRisk(risk) : CalcLotByBalance();

   Print("[SELL] Placing | lot=",lotTotal," tp=",DoubleToString(tp,2));
   TG_OnSignal((int)POSITION_TYPE_SELL, entry, sl, tp, lotTotal);

   if(!trade.Sell(lotTotal,_Symbol,0,0,0,OrderCommentWithTf("SELL")))
   { Print("[SELL] ORDER FAILED: ",trade.ResultRetcodeDescription());
     TG_Send("⚠️ <b>SELL FAILED</b>\n"+_Symbol+"\n"+trade.ResultRetcodeDescription()); return; }

   ulong ticket=trade.ResultDeal();
   if(ticket==0) ticket=GetTicketByDeal();
   if(ticket==0) { Print("[SELL] Cannot get ticket"); return; }

   double fp=trade.ResultPrice(); if(fp>0) entry=fp;
   risk=sl-entry; if(risk<_Point*5) risk=_Point*5;
   tp=entry-risk*RR;

   gTrade.ticket=ticket; gTrade.ticket2=0; gTrade.dir=(int)POSITION_TYPE_SELL; gTrade.entry=entry;
   gTrade.sl=sl; gTrade.tp=tp; gTrade.active=true; gTrade.breakevenDone=false;

   DrawBoxes(entry,sl,tp);
   Print("[SELL] OPENED ✅ | Fill=",entry," SL=",sl," TP=",tp," Lot=",lotTotal," Ticket=",ticket);
   MarkFiredThisBar(iTime(_Symbol,PERIOD_CURRENT,0));
   TG_OnOpen((int)POSITION_TYPE_SELL,entry,sl,tp,lotTotal,ticket);
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
   return (lastSellFireBar==barTime);
}
void MarkFiredThisBar(datetime barTime)
{
   lastSellFireBar=barTime;
}

//====================================================================
void DrawBoxes(double entry, double sl, double tp)
{
   DeleteAllBoxObjects();
   datetime t1=iTime(_Symbol,PERIOD_CURRENT,1);
   datetime t2=iTime(_Symbol,PERIOD_CURRENT,0)+(datetime)PeriodSeconds(PERIOD_CURRENT)*BoxExtendBars;

   ObjectCreate(0,"GPS_H1_EntryLine",OBJ_TREND,0,t1,entry,t2,entry);
   ObjectSetInteger(0,"GPS_H1_EntryLine",OBJPROP_COLOR,ColorEntryLine);
   ObjectSetInteger(0,"GPS_H1_EntryLine",OBJPROP_WIDTH,2);
   ObjectSetInteger(0,"GPS_H1_EntryLine",OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,"GPS_H1_EntryLine",OBJPROP_RAY_RIGHT,false);
   ObjectSetInteger(0,"GPS_H1_EntryLine",OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,"GPS_H1_EntryLine",OBJPROP_HIDDEN,true);

   double slTop=sl, slBot=entry;
   ObjectCreate(0,"GPS_H1_SLBox",OBJ_RECTANGLE,0,t1,slTop,t2,slBot);
   ObjectSetInteger(0,"GPS_H1_SLBox",OBJPROP_COLOR,ColorSLBox);
   ObjectSetInteger(0,"GPS_H1_SLBox",OBJPROP_FILL,true);
   ObjectSetInteger(0,"GPS_H1_SLBox",OBJPROP_BACK,true);
   ObjectSetInteger(0,"GPS_H1_SLBox",OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,"GPS_H1_SLBox",OBJPROP_HIDDEN,true);

   double tpTop=entry, tpBot=tp;
   ObjectCreate(0,"GPS_H1_TPBox",OBJ_RECTANGLE,0,t1,tpTop,t2,tpBot);
   ObjectSetInteger(0,"GPS_H1_TPBox",OBJPROP_COLOR,ColorTPBox);
   ObjectSetInteger(0,"GPS_H1_TPBox",OBJPROP_FILL,true);
   ObjectSetInteger(0,"GPS_H1_TPBox",OBJPROP_BACK,true);
   ObjectSetInteger(0,"GPS_H1_TPBox",OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,"GPS_H1_TPBox",OBJPROP_HIDDEN,true);

   string dirTxt="▼ SELL";
   color  dirClr=clrTomato;
   DrawPriceLabel("GPS_H1_LabelDir",dirTxt,t1,entry,dirClr);
   DrawPriceLabel("GPS_H1_LabelEN","Entry: "+DoubleToString(entry,_Digits),t2,entry,ColorEntryLine);
   DrawPriceLabel("GPS_H1_LabelSL","SL: "+DoubleToString(sl,_Digits),t2,sl,ColorSLBox);
   DrawPriceLabel("GPS_H1_LabelTP","TP: "+DoubleToString(tp,_Digits),t2,tp,ColorTPBox);
   ChartRedraw(0);
}

void ExtendBoxes()
{
   datetime t2=iTime(_Symbol,PERIOD_CURRENT,0)+(datetime)PeriodSeconds(PERIOD_CURRENT)*BoxExtendBars;
   string objs[]={"GPS_H1_EntryLine","GPS_H1_SLBox","GPS_H1_TPBox","GPS_H1_LabelEN","GPS_H1_LabelSL","GPS_H1_LabelTP","GPS_H1_LabelDir","GPS_H1_BELine"};
   for(int i=0;i<ArraySize(objs);i++)
      if(ObjectFind(0,objs[i])>=0)
         ObjectSetInteger(0,objs[i],OBJPROP_TIME,1,t2);
}

void DrawMALines(int barsBack)
{
   for(int i=0;i<barsBack;i++)
   {
      string fn="GPS_H1_FastMA_"+IntegerToString(i);
      string sn="GPS_H1_SlowMA_"+IntegerToString(i);
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
      string fn="GPS_H1_FastMA_"+IntegerToString(i);
      ObjectCreate(0,fn,OBJ_TREND,0,t1,fastMA[i+1],t2,fastMA[i]);
      ObjectSetInteger(0,fn,OBJPROP_COLOR,clrDodgerBlue); ObjectSetInteger(0,fn,OBJPROP_WIDTH,2);
      ObjectSetInteger(0,fn,OBJPROP_STYLE,STYLE_SOLID);   ObjectSetInteger(0,fn,OBJPROP_RAY_RIGHT,false);
      ObjectSetInteger(0,fn,OBJPROP_SELECTABLE,false);    ObjectSetInteger(0,fn,OBJPROP_BACK,true);
      ObjectSetInteger(0,fn,OBJPROP_HIDDEN,true);
      string sn="GPS_H1_SlowMA_"+IntegerToString(i);
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
   ObjectSetDouble(0,"GPS_H1_SLBox",OBJPROP_PRICE,0,slPrice); ObjectSetDouble(0,"GPS_H1_SLBox",OBJPROP_PRICE,1,slPrice);
   ObjectSetString(0,"GPS_H1_LabelSL",OBJPROP_TEXT,"BE+: "+DoubleToString(slPrice,_Digits));
   ObjectSetInteger(0,"GPS_H1_LabelSL",OBJPROP_COLOR,clrGold);
   ObjectSetDouble(0,"GPS_H1_LabelSL",OBJPROP_PRICE,slPrice);
   datetime t1=iTime(_Symbol,PERIOD_CURRENT,1);
   datetime t2=iTime(_Symbol,PERIOD_CURRENT,0)+(datetime)PeriodSeconds(PERIOD_CURRENT)*BoxExtendBars;
   if(ObjectFind(0,"GPS_H1_BELine")<0) ObjectCreate(0,"GPS_H1_BELine",OBJ_TREND,0,t1,slPrice,t2,slPrice);
   ObjectSetDouble(0,"GPS_H1_BELine",OBJPROP_PRICE,0,slPrice); ObjectSetDouble(0,"GPS_H1_BELine",OBJPROP_PRICE,1,slPrice);
   ObjectSetInteger(0,"GPS_H1_BELine",OBJPROP_COLOR,clrGold); ObjectSetInteger(0,"GPS_H1_BELine",OBJPROP_WIDTH,2);
   ObjectSetInteger(0,"GPS_H1_BELine",OBJPROP_STYLE,STYLE_DASH); ObjectSetInteger(0,"GPS_H1_BELine",OBJPROP_RAY_RIGHT,false);
   ObjectSetInteger(0,"GPS_H1_BELine",OBJPROP_SELECTABLE,false); ObjectSetInteger(0,"GPS_H1_BELine",OBJPROP_HIDDEN,true);
   ChartRedraw(0);
}

void DeleteAllBoxObjects()
{
   string objs[]={"GPS_H1_EntryLine","GPS_H1_SLBox","GPS_H1_TPBox","GPS_H1_LabelEN","GPS_H1_LabelSL","GPS_H1_LabelTP","GPS_H1_LabelDir","GPS_H1_BELine"};
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
   string name="GPS_H1_Hit_"+IntegerToString(GetTickCount());
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

string DashboardSubtitleSell()
{
   return DashboardSymbolPretty()+"     ·     Auto Trade     ·     SELL     ·     "+ChartTfShort();
}

//====================================================================
void DrawInfoPanel(double fast, double slow, bool sellSignal, double price)
{
   string obsolete[]={
      "GPS_H1_DIR","GPS_H1","GPS_H1_A1","GPS_H1_A2","GPS_H1_H2","GPS_H1_D0","GPS_H1_D1","GPS_H1_D2","GPS_H1_D3",
      "GPS_H1_H3","GPS_H1_S1","GPS_H1_S2","GPS_H1_H4","GPS_H1_P2","GPS_H1_P3","GPS_H1_P4","GPS_H1_P5",
      "GPS_DIR","GPS_H1","GPS_A1","GPS_A2","GPS_H2","GPS_D0","GPS_D1","GPS_D2","GPS_D3",
      "GPS_H3","GPS_S1","GPS_S2","GPS_H4","GPS_P2","GPS_P3","GPS_P4","GPS_P5"
   };
   for(int oi=0;oi<ArraySize(obsolete);oi++)
      if(ObjectFind(0,obsolete[oi])>=0) ObjectDelete(0,obsolete[oi]);

   string currency=AccountInfoString(ACCOUNT_CURRENCY);
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyPnL=CalcDailyClosedPnL();
   double floatMoney=0.0;
   if(gTrade.active) floatMoney=GetFloatingPnLBoth();
   double totalDayPnL=dailyPnL+floatMoney;

   string sigText=sellSignal?"▼  SELL":"○  WAIT";
   color  sigClr=sellSignal?clrTomato:clrGray;

   int x=12,y=10,dyTitle=22,dySub=15,dy=15;

   GPS_H1_Label("GPS_H1_H0","TVH-Smile",x,y,clrDeepSkyBlue,12,true); y+=dyTitle;
   GPS_H1_Label("GPS_H1_TS",DashboardSubtitleSell(),x,y,clrSilver,9,false); y+=dySub;
   GPS_H1_Label("GPS_H1_S0","Signal     "+sigText,x,y,sigClr,10,true); y+=dy;
   GPS_H1_Label("GPS_H1_A0","Balance  "+DoubleToString(balance,2)+" "+currency+
      "     ·     Today  "+(totalDayPnL>=0?"+":"")+DoubleToString(totalDayPnL,2)+" "+currency,
      x,y,(totalDayPnL>=0?clrWhite:clrTomato),9,false); y+=dy;

   if(gTrade.active)
   {
      if(ObjectFind(0,"GPS_H1_P0")>=0) ObjectDelete(0,"GPS_H1_P0");
      double pnlPts=(gTrade.entry-price)/_Point;
      string posLine=(gTrade.ticket2>0?"2 legs · ":"")+
         "Entry "+DoubleToString(gTrade.entry,_Digits)+
         "     ·     SL "+DoubleToString(gTrade.sl,_Digits)+
         "     ·     TP "+DoubleToString(gTrade.tp,_Digits)+
         "     ·     P/L "+(floatMoney>=0?"+":"")+DoubleToString(floatMoney,2)+" "+
         currency+"  ("+(pnlPts>=0?"+":"")+DoubleToString(pnlPts,0)+" pt)";
      GPS_H1_Label("GPS_H1_P1",posLine,x,y,(pnlPts>=0?clrLime:clrTomato),9,false); y+=dy;
   }
   else
   {
      if(ObjectFind(0,"GPS_H1_P1")>=0) ObjectDelete(0,"GPS_H1_P1");
      GPS_H1_Label("GPS_H1_P0","○  No open position",x,y,clrDarkGray,9,false); y+=dy;
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
   GPS_H1_Label("GPS_H1_F0",foot,x,y,footClr,8,false);
}

void GPS_H1_Label(string name, string txt, int x, int y, color clr, int sz, bool bold)
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
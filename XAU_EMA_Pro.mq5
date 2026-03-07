//+------------------------------------------------------------------+
//|                                     XAU_PRO_V2_AGGRESSIVE        |
//|                    Professional Gold EA - High Frequency Mode    |
//+------------------------------------------------------------------+
#property copyright "HoangDev & Gemini AI"
#property version   "2.15"
#property strict

#include <Trade/Trade.mqh>

//--- INPUT PARAMETERS
input group "--- Money Management ---"
input ulong  MagicNumber      = 240304;
input bool   AutoLot          = true;
input double RiskPer1000      = 0.015;
input double ManualLot        = 0.01;

input group "--- Strategy (Nới lỏng bộ lọc) ---"
input ENUM_TIMEFRAMES EntryTF = PERIOD_M5;
input int    FastEMA          = 9;
input int    SlowEMA          = 21;
input double ATR_Min          = 1; // Hạ thấp để vào lệnh cả khi sóng yếu

input group "--- Safety & Trailing ---"
input int    MaxSpread        = 500; // Tăng lên để chấp nhận spread cao hơn
input double TrailingStartUSD = 30.0; // Chốt lời sớm hơn
input double TrailingStepUSD  = 10.0;
input double TrailingBufferUSD= 1.0;
input double MaxLossUSD       = 20.0;
input double DailyLossLimit   = -100.0;
input int    CooldownBars     = 1;   // Đợi ít hơn giữa các lệnh

input group "--- Session ---"
input int SessionStartHour    = 0;   // Chạy cả ngày
input int SessionEndHour      = 23;

//--- GLOBAL VARIABLES
CTrade   trade;
int      fastH, slowH, atrH;
datetime lastBar = 0;
int      barsAfterClose = 100;
double   maxProfitUSD = 0;
double   trailingLevelUSD = 0;
bool     trailingActive = false;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   fastH      = iMA(_Symbol, EntryTF, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   slowH      = iMA(_Symbol, EntryTF, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   atrH       = iATR(_Symbol, EntryTF, 14);

   if(fastH == INVALID_HANDLE || slowH == INVALID_HANDLE) return(INIT_FAILED);
   ObjectsDeleteAll(0, "UI_");
   UpdateDashboard();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { ObjectsDeleteAll(0, "UI_"); ChartRedraw(0); }

void OnTick()
{
   ManagePosition();
   UpdateDashboard();
   
   datetime currentBar = iTime(_Symbol, EntryTF, 0);
   if(currentBar != lastBar)
   {
      lastBar = currentBar;
      barsAfterClose++;
      CheckSignal();
   }
}

//+------------------------------------------------------------------+
//| CHIẾN THUẬT NỚI LỎNG: CỨ CẮT LÀ VÀO                              |
//+------------------------------------------------------------------+
void CheckSignal()
{
   if(GetTodayProfit() <= DailyLossLimit) return;
   if(GetSpread() > MaxSpread || barsAfterClose < CooldownBars) return;

   double f[3], s[3], a[1];
   if(CopyBuffer(fastH, 0, 0, 3, f) < 3) return;
   if(CopyBuffer(slowH, 0, 0, 3, s) < 3) return;
   if(CopyBuffer(atrH, 0, 0, 1, a) < 1) return;

   // ĐIỀU KIỆN ĐƠN GIẢN: CHỈ CẦN EMA CẮT NHAU
   bool buyCross  = (f[1] > s[1] && f[2] <= s[2]);
   bool sellCross = (f[1] < s[1] && f[2] >= s[2]);

   ulong currentTicket = GetMagicTicket();

   if(buyCross && a[0] > ATR_Min) 
   {
      if(currentTicket > 0) 
      {
         if(PositionSelectByTicket(currentTicket))
         {
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) trade.PositionClose(currentTicket);
            else return;
         }
      }
      ExecuteOrder(ORDER_TYPE_BUY, a[0]);
   }

   if(sellCross && a[0] > ATR_Min) 
   {
      if(currentTicket > 0) 
      {
         if(PositionSelectByTicket(currentTicket))
         {
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) trade.PositionClose(currentTicket);
            else return;
         }
      }
      ExecuteOrder(ORDER_TYPE_SELL, a[0]);
   }
}

void ExecuteOrder(ENUM_ORDER_TYPE type, double atrVal)
{
   double lot   = GetLotSize();
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tp    = (type == ORDER_TYPE_BUY) ? price + (atrVal * 10) : price - (atrVal * 10);
   
   if(trade.PositionOpen(_Symbol, type, lot, price, 0, tp, "XAU AGGRESSIVE")) 
   { 
      ResetTrailing(); 
      barsAfterClose = 0; 
      ulong ticket = GetMagicTicket();
      if(ticket > 0) DrawEntryBox(type, ticket);
   }
}

void DrawEntryBox(ENUM_ORDER_TYPE type, ulong ticket)
{
   datetime t1 = iTime(_Symbol, EntryTF, 1);
   datetime t2 = iTime(_Symbol, EntryTF, 0);
   double h = iHigh(_Symbol, EntryTF, 1);
   double l = iLow(_Symbol, EntryTF, 1);
   string name = "BOX_" + IntegerToString(ticket);
   color col = (type == ORDER_TYPE_BUY) ? clrSkyBlue : clrTomato;
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, h, t2, l);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
}

double GetPositionNetProfit(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return 0;
   double p = PositionGetDouble(POSITION_PROFIT), s = PositionGetDouble(POSITION_SWAP), c = 0;
   long id = PositionGetInteger(POSITION_IDENTIFIER);
   if(HistorySelectByPosition(id))
      for(int i=0; i<HistoryDealsTotal(); i++) c += HistoryDealGetDouble(HistoryDealGetTicket(i), DEAL_COMMISSION);
   return p + s + c;
}

void ManagePosition()
{
   ulong ticket = GetMagicTicket();
   if(ticket == 0) { ResetTrailing(); return; }
   double netP = GetPositionNetProfit(ticket);
   if(netP > maxProfitUSD) maxProfitUSD = netP;
   if(!trailingActive && maxProfitUSD >= TrailingStartUSD) { trailingActive = true; trailingLevelUSD = maxProfitUSD - TrailingBufferUSD; }
   if(trailingActive) {
      double pot = maxProfitUSD - TrailingBufferUSD;
      if(pot >= trailingLevelUSD + TrailingStepUSD) trailingLevelUSD = pot;
      if(netP <= trailingLevelUSD || netP <= -MaxLossUSD) trade.PositionClose(ticket);
   }
}

void UpdateDashboard()
{
   int x = 20, y = 20;
   double a[1]; double curATR = (CopyBuffer(atrH, 0, 0, 1, a) > 0) ? a[0] : 0;
   DrawRect("UI_BG", x, y, 280, 150, C'20,20,20');
   DrawText("UI_T", "XAU AGGRESSIVE MODE", x+10, y+10, 10, clrOrange);
   DrawText("UI_E", "EQUITY: "+DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2), x+10, y+40, 8, clrWhite);
   DrawText("UI_P", "DAILY: "+DoubleToString(GetTodayProfit(),2), x+10, y+60, 8, clrLime);
   DrawText("UI_A", "ATR: "+DoubleToString(curATR,2), x+10, y+85, 8, clrYellow);
   DrawText("UI_S", "STATUS: RUNNING...", x+10, y+110, 9, clrCyan);
   ChartRedraw(0);
}

void DrawText(string name, string text, int x, int y, int size, color col)
{
   if(ObjectFind(0, name) < 0) ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x); ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col); ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}

void DrawRect(string name, int x, int y, int w, int h, color col)
{
   if(ObjectFind(0, name) < 0) ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x); ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w); ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, col);
}

double GetLotSize()
{
   if(!AutoLot) return ManualLot;
   double lot = (AccountInfoDouble(ACCOUNT_EQUITY) / 1000.0) * RiskPer1000;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / step) * step;
   return MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), lot);
}

ulong GetMagicTicket()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) return t;
   }
   return 0;
}

double GetTodayProfit()
{
   double p = 0;
   if(HistorySelect(iTime(_Symbol, PERIOD_D1, 0), TimeCurrent()))
      for(int i=0; i<HistoryDealsTotal(); i++) {
         ulong t = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(t, DEAL_MAGIC) == MagicNumber) p += HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_COMMISSION) + HistoryDealGetDouble(t, DEAL_SWAP);
      }
   return p;
}

double GetSpread() { return (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point; }
void ResetTrailing() { maxProfitUSD = 0; trailingLevelUSD = 0; trailingActive = false; }
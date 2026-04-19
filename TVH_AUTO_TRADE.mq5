//+------------------------------------------------------------------+
//|                                    TVH_AUTO_TRADE.mq5             |
//|  EMA 34/89 + khung giờ máy (4 cửa sổ) + MACD/CCI + trailing ẩo  |
//|  Bản test — một lệnh / magic, SL/TP ẩo quản lý trong EA         |
//+------------------------------------------------------------------+
#property copyright "TVH Auto Trade"
#property version   "1.09"
#property description "EMA34-89 — BUY / SELL / cả hai nếu đủ điều kiện; Sync→MonitorTrade→phiên→vào lệnh"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

CTrade        trade;
CPositionInfo pos;

//====================================================================
enum ENUM_TRADE_SIDE
  {
   SIDE_BUY_ONLY      = 0,
   SIDE_SELL_ONLY     = 1,
   SIDE_BUY_AND_SELL  = 2   // Xét BUY và SELL; MaxPositions=1 thì một lệnh/lần (ưu tiên khi cả hai khớp)
  };

enum ENUM_BOTH_PRIORITY
  {
   BOTH_PRIO_BUY_FIRST  = 0,  // Cùng bar cả BUY & SELL đạt filter → mở BUY
   BOTH_PRIO_SELL_FIRST = 1   // Cùng bar cả hai đạt → mở SELL
  };

enum ENUM_ENTRY_SIGNAL
  {
   ENTRY_NONE       = 0,  // Không điều kiện (vẫn tôn trọng bộ lọc EMA/MACD/CCI nếu bật)
   ENTRY_EMA_CROSS  = 1,  // Cắt lên (BUY) / cắt xuống (SELL)
   ENTRY_EMA_TREND  = 2   // Trend: BUY EMA34>EMA89; SELL EMA34<EMA89
  };

// Giống Sell_only_m5: OPEN_NEXT_BAR = chỉ xét khi sang nến mới EntryTF; CLOSE_SIGNAL = cắt trên nến đang chạy, 1 lần/nến
enum ENUM_ENTRY_TIMING
  {
   ENTRY_TIMING_NEW_BAR      = 0,
   ENTRY_TIMING_CLOSE_SIGNAL = 1
  };

// SL/TP ẩo: pip cố định hoặc swing + RR (như BUY_ONLY_H4 / Sell_only_m5)
enum ENUM_SLTP_MODE
  {
   SLTP_MODE_PIPS          = 0,
   SLTP_MODE_SWING_RR      = 1,
   SLTP_MODE_FIXED_POINTS  = 2   // SL/TP theo point tài khoản: khoảng giá = N / FixedPointsPerUsd (vd 1000=1 USD giá)
  };

//====================================================================
//--- Trailing (ẩo, trong EA)
input group    "=== Trailing (ẩo, trong EA) ==="
input bool     UseVirtTrailing         = false; // true = kéo SL theo pip; false = chỉ đóng theo SL/TP ẩo (tránh đóng ngay do BE)
input double   TrailStepPips           = 5.0;   // Bước trailing, pips
input double   FirstTrailPips          = 20.0;  // Lợi nhuận pip để bật trail (tăng nếu bật UseVirtTrailing)
input double   InitialStopLossPips     = 30.0;  // Chỉ dùng khi SltpMode=PIPS: SL (pip)
input double   TakeProfitPips          = 0.0;   // Chỉ dùng khi SltpMode=PIPS: TP pip; 0 = không TP cố định
input int      PointsPerPip            = 10;   // 10 = FX 5 số; vàng 2 số thường 1 hoặc 10

//--- SL/TP cố định: 1000 point input = 1.00 giá (USD trên XAU); không phụ thuộc _Point MT5
input group    "=== SL/TP cố định (point tài khoản — 1000 = 1 USD giá) ==="
input int      FixedPointsPerUsd       = 1000;  // Khoảng giá = StopLossPoints / FixedPointsPerUsd (vd 200 → 0.20 giá)
input int      StopLossPoints          = 200;   // SL: số point theo quy ước trên (200/1000=0.20 giá nếu scale=1000)
input int      TakeProfitPoints        = 600;   // TP: 600/1000=0.60 giá (1:3 với SL 200); 0 = không TP ẩo

//--- SL/TP tự tính (swing + RR)
input group    "=== SL/TP swing + RR (như GoldPro) ==="
input ENUM_SLTP_MODE SltpMode          = SLTP_MODE_FIXED_POINTS;
input ENUM_TIMEFRAMES SwingTF          = PERIOD_CURRENT; // Khung tìm đỉnh/đáy swing
input int      SwingLookback           = 20;
input double   RiskReward              = 3.0;   // TP = entry ± risk×RR; 0 = không TP ẩo (chỉ SL+trail)
input double   SLExtraPrice            = 0.0;   // Dịch mức SL (giá): BUY thường + = SL cao hơn (chặt hơn)

//--- Giờ máy (PC) — phút trong ngày
input group    "=== Giới hạn thời gian (giờ máy / PC) ==="
input bool     UseMasterTimeFilter     = true; // false = giao dịch mọi giờ
input bool     UseWindow1              = true;
input string   Win1_Start              = "08:30";
input string   Win1_End                = "12:30";
input bool     UseWindow2              = true;
input string   Win2_Start              = "14:30";
input string   Win2_End                = "18:30";
input bool     UseWindow3              = true;
input string   Win3_Start              = "20:30";
input string   Win3_End                = "23:30";
input bool     UseWindow4              = true;
input string   Win4_Start              = "02:30";
input string   Win4_End                = "05:30";
input bool     ManageOutsideSessions   = true; // true = vẫn trailing/đóng lệnh ngoài khung giờ

//--- Vào lệnh
input group    "=== Điều kiện mở lệnh ==="
input ENUM_ENTRY_TIMING EntryTiming     = ENTRY_TIMING_NEW_BAR;
input ENUM_ENTRY_SIGNAL EntrySignal    = ENTRY_EMA_CROSS;
input ENUM_TIMEFRAMES   EntryTF        = PERIOD_CURRENT;
input ENUM_TRADE_SIDE   TradeSide      = SIDE_BUY_ONLY;
input ENUM_BOTH_PRIORITY BothSignalsPriority = BOTH_PRIO_BUY_FIRST; // Chỉ khi TradeSide = BUY+SELL: cùng nến cả hai phía đạt filter

//--- EMA
input group    "=== Bộ lọc EMA ==="
input bool     UseEMAFilter            = true;
input ENUM_TIMEFRAMES   EmaTF          = PERIOD_CURRENT;
input int      EmaFastPeriod           = 34;
input int      EmaSlowPeriod           = 89;
input ENUM_APPLIED_PRICE EmaApplied    = PRICE_CLOSE;

//--- MACD
input group    "=== Bộ lọc MACD ==="
input bool     UseMACDFilter           = false;
input ENUM_TIMEFRAMES   MacdTF         = PERIOD_CURRENT;
input int      MacdFast                = 30;
input int      MacdSlow                = 50;
input int      MacdSignal              = 5;
input ENUM_APPLIED_PRICE MacdApplied   = PRICE_TYPICAL;

//--- CCI
input group    "=== Bộ lọc CCI ==="
input bool     UseCCIFilter            = false;
input ENUM_TIMEFRAMES   CciTF          = PERIOD_CURRENT;
input int      CciPeriod               = 14;
input ENUM_APPLIED_PRICE CciApplied    = PRICE_CLOSE;
input double   CciOverbought         = 100.0;
input double   CciOversold             = -100.0;

//--- Giao dịch
input group    "=== Lot / Magic ==="
input double   Lots                    = 0.01;
input ulong    MagicNumber             = 303034;
input int      SlippagePoints          = 30;
input int      MaxPositions            = 1;
input int      ExitGraceSeconds        = 0;   // 0 = giống GoldPro (đóng SL/TP ngay khi chạm); >0 = trì hoãn đóng SL/TP ẩo
input bool     DetailedTradeLog        = true; // Log Experts: lý do mở/đóng, filter, sync (tắt nếu quá nhiều dòng)

//--- Hiển thị SL/TP ẩo trên chart (hộp + đường entry)
input group    "=== Box SL/TP trên chart ==="
input bool     DrawSltpBoxes           = true;
input int      BoxExtendBars           = 120;  // Kéo cạnh phải box thêm N nến chart hiện tại
input color    ColorBoxSL              = clrCrimson;
input color    ColorBoxTP              = clrForestGreen;
input color    ColorBoxEntry           = clrWhite;

//====================================================================
datetime g_lastEntryEvalBar = 0; // NEW_BAR: đã xét tín hiệu trên nến này của EntryTF
datetime g_firedSignalBar   = 0; // CLOSE_SIGNAL: đã vào lệnh trên nến này
datetime g_posOpenTime      = 0;
double   g_virtSL        = 0.0;
double   g_virtTP        = 0.0;
bool     g_trailArmed    = false;
double   g_trailRef      = 0.0;   // mốc giá cho bước trailing
ulong    g_ticket        = 0;
ulong    g_loggedGraceTicket = 0; // đã in log grace cho ticket này chưa

int hEmaFast = INVALID_HANDLE;
int hEmaSlow = INVALID_HANDLE;
int hMacd    = INVALID_HANDLE;
int hCci     = INVALID_HANDLE;

//====================================================================
double PipPrice()
{
   return (double)PointsPerPip * _Point;
}

// FIXED_POINTS: quy đổi point input → khoảng giá (FixedPointsPerUsd point = 1.0 giá)
double FixedPointPriceFromInput(const int inputPts)
{
   int s=FixedPointsPerUsd;
   if(s<1) s=1000;
   return (double)inputPts/(double)s;
}

// Khoảng cách SL ẩo tối thiểu: tránh SL = entry (đóng ngay) hoặc SL trong spread
double MinVirtualSlDistance()
{
   long st=(long)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double brok=(st>0)?(double)st*_Point:5.0*_Point;
   double spr=(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)*_Point;
   return brok + spr + 5.0*_Point;
}

double AddExtraSlPrice(const double sl)
{
   if(SLExtraPrice==0.0) return NormalizeDouble(sl,_Digits);
   return NormalizeDouble(sl+SLExtraPrice,_Digits);
}

double GetSwingLowTF(const int lookback,const ENUM_TIMEFRAMES tf)
{
   int lb=MathMax(lookback,3);
   for(int i=2;i<=lb-1;i++)
   {
      double cur=iLow(_Symbol,tf,i);
      double prev=iLow(_Symbol,tf,i+1);
      double next=iLow(_Symbol,tf,i-1);
      if(cur<prev && cur<next) return cur;
   }
   double v=DBL_MAX;
   for(int i=1;i<=lb;i++)
   {
      double l=iLow(_Symbol,tf,i);
      if(l<v) v=l;
   }
   if(v==DBL_MAX) v=iLow(_Symbol,tf,1);
   return v;
}

double GetSwingHighTF(const int lookback,const ENUM_TIMEFRAMES tf)
{
   int lb=MathMax(lookback,3);
   for(int i=2;i<=lb-1;i++)
   {
      double cur=iHigh(_Symbol,tf,i);
      double prev=iHigh(_Symbol,tf,i+1);
      double next=iHigh(_Symbol,tf,i-1);
      if(cur>prev && cur>next) return cur;
   }
   double v=0.0;
   for(int i=1;i<=lb;i++)
   {
      double h=iHigh(_Symbol,tf,i);
      if(h>v) v=h;
   }
   if(v<=0.0) v=iHigh(_Symbol,tf,1);
   return v;
}

// SL/TP ẩo (giá); false = không đủ khoảng swing / risk
bool ComputeSwingVirtLevels(const bool isBuy,const double entry,double &outSL,double &outTP)
{
   ENUM_TIMEFRAMES stf=TFOrCurrent(SwingTF);
   outTP=0.0;
   double minD=MinVirtualSlDistance();
   if(isBuy)
   {
      double sl=AddExtraSlPrice(GetSwingLowTF(SwingLookback,stf));
      double risk=entry-sl;
      if(risk<minD)
      {
         sl=NormalizeDouble(entry-minD,_Digits);
         risk=entry-sl;
      }
      if(sl>=entry || risk<minD*0.5) return false;
      outSL=NormalizeDouble(sl,_Digits);
      outTP=(RiskReward>0.0)?NormalizeDouble(entry+risk*RiskReward,_Digits):0.0;
      return true;
   }
   double sl=AddExtraSlPrice(GetSwingHighTF(SwingLookback,stf));
   double risk=sl-entry;
   if(risk<minD)
   {
      sl=NormalizeDouble(entry+minD,_Digits);
      risk=sl-entry;
   }
   if(sl<=entry || risk<minD*0.5) return false;
   outSL=NormalizeDouble(sl,_Digits);
   outTP=(RiskReward>0.0)?NormalizeDouble(entry-risk*RiskReward,_Digits):0.0;
   return true;
}

// SL/TP ẩo: khoảng giá = StopLossPoints/FixedPointsPerUsd (vd 1000 pt = 1.0 giá), sàn MinVirtualSlDistance()
void ApplyFixedPointVirtLevels(const bool isBuy,const double entry,double &outDistSL)
{
   int slPts=StopLossPoints;
   if(slPts<1) slPts=1;
   const double rawSlDist=FixedPointPriceFromInput(slPts);
   const double rawTpDist=(TakeProfitPoints>0)?FixedPointPriceFromInput(TakeProfitPoints):0.0;
   const double minD=MinVirtualSlDistance();
   double slDist=MathMax(rawSlDist,minD);
   outDistSL=slDist;
   double tpDist=0.0;
   if(TakeProfitPoints>0)
      tpDist=MathMax(rawTpDist,minD);
   const int scale=(FixedPointsPerUsd>=1)?FixedPointsPerUsd:1000;
   if(DetailedTradeLog && (slDist>rawSlDist+_Point*0.5 || (TakeProfitPoints>0 && tpDist>rawTpDist+_Point*0.5)))
      Print("[TVH] FIXED point: khoảng yêu cầu < min spread/stops — dùng tối thiểu ~",
            DoubleToString(minD*(double)scale,1)," pt (",scale,"/USD) | min giá=",DoubleToString(minD,_Digits),
            " | SL yêu cầu ",slPts," pt → thực ",DoubleToString(slDist*(double)scale,1)," pt",
            (TakeProfitPoints>0?" | TP thực "+DoubleToString(tpDist*(double)scale,1)+" pt":""));
   if(isBuy)
   {
      g_virtSL=NormalizeDouble(entry-slDist,_Digits);
      g_virtTP=(tpDist>0.0)?NormalizeDouble(entry+tpDist,_Digits):0.0;
   }
   else
   {
      g_virtSL=NormalizeDouble(entry+slDist,_Digits);
      g_virtTP=(tpDist>0.0)?NormalizeDouble(entry-tpDist,_Digits):0.0;
   }
}

void RestoreVirtLevelsForOpenPosition()
{
   if(g_ticket==0 || !pos.SelectByTicket(g_ticket)) return;
   double e=pos.PriceOpen();
   bool isBuy=(pos.PositionType()==POSITION_TYPE_BUY);
   double dist=0.0;
   if(SltpMode==SLTP_MODE_SWING_RR)
   {
      if(!ComputeSwingVirtLevels(isBuy,e,g_virtSL,g_virtTP))
      {
         double want=InitialStopLossPips*PipPrice();
         dist=MathMax(want,MinVirtualSlDistance());
         if(isBuy)
         {
            g_virtSL=NormalizeDouble(e-dist,_Digits);
            g_virtTP=(TakeProfitPips>0.0)?NormalizeDouble(e+TakeProfitPips*PipPrice(),_Digits):0.0;
         }
         else
         {
            g_virtSL=NormalizeDouble(e+dist,_Digits);
            g_virtTP=(TakeProfitPips>0.0)?NormalizeDouble(e-TakeProfitPips*PipPrice(),_Digits):0.0;
         }
         Print("TVH: khôi phục SL/TP — swing lỗi, dùng pip fallback");
      }
   }
   else if(SltpMode==SLTP_MODE_FIXED_POINTS)
   {
      ApplyFixedPointVirtLevels(isBuy,e,dist);
   }
   else
   {
      double want=InitialStopLossPips*PipPrice();
      dist=MathMax(want,MinVirtualSlDistance());
      if(isBuy)
      {
         g_virtSL=NormalizeDouble(e-dist,_Digits);
         g_virtTP=(TakeProfitPips>0.0)?NormalizeDouble(e+TakeProfitPips*PipPrice(),_Digits):0.0;
      }
      else
      {
         g_virtSL=NormalizeDouble(e+dist,_Digits);
         g_virtTP=(TakeProfitPips>0.0)?NormalizeDouble(e-TakeProfitPips*PipPrice(),_Digits):0.0;
      }
   }
   SanitizeVirtualStopsAfterOpen(isBuy,e);
   g_trailArmed=false;
   g_trailRef=0.0;
   DrawSltpBoxesOnChart(isBuy,e,g_virtSL,g_virtTP);
   if(DetailedTradeLog)
      Print("[TVH] SYNC | Khôi phục Virt SL/TP sau attach | ticket=",g_ticket,
            " | ",(isBuy?"BUY":"SELL")," | entry=",DoubleToString(e,_Digits),
            " | VirtSL=",DoubleToString(g_virtSL,_Digits)," | VirtTP=",DoubleToString(g_virtTP,_Digits),
            " | SltpMode=",SltpMode);
}

// SL/TP ẩo: chỉnh nếu nằm sai phía so với bid/ask lúc mở (áp cả FIXED_POINTS sau khi đã sàn min)
void SanitizeVirtualStopsAfterOpen(const bool isBuy,const double entry)
{
   long st=(long)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minMove=(st>0)?(double)st*_Point:5.0*_Point;
   minMove+=MathMax((double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)*_Point,3.0*_Point);

   if(isBuy)
   {
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      if(g_virtSL>0.0 && bid<=g_virtSL)
         g_virtSL=NormalizeDouble(bid-minMove,_Digits);
      if(g_virtTP>0.0 && bid>=g_virtTP)
         g_virtTP=NormalizeDouble(bid+minMove,_Digits);
      if(g_virtSL>0.0 && g_virtSL>=entry)
         g_virtSL=NormalizeDouble(entry-minMove,_Digits);
   }
   else
   {
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      if(g_virtSL>0.0 && ask>=g_virtSL)
         g_virtSL=NormalizeDouble(ask+minMove,_Digits);
      if(g_virtTP>0.0 && ask<=g_virtTP)
         g_virtTP=NormalizeDouble(ask-minMove,_Digits);
      if(g_virtSL>0.0 && g_virtSL<=entry)
         g_virtSL=NormalizeDouble(entry+minMove,_Digits);
   }
}

//--------------------------------------------------------------------
bool ParseHHMM(const string s,int &h,int &m)
{
   string t=s;
   StringTrimLeft(t); StringTrimRight(t);
   if(StringLen(t)<4) return false;
   int p=StringFind(t,":");
   if(p<=0) return false;
   h=(int)StringToInteger(StringSubstr(t,0,p));
   m=(int)StringToInteger(StringSubstr(t,p+1));
   return (h>=0 && h<=23 && m>=0 && m<=59);
}

int MinutesNowLocal()
{
   MqlDateTime dt;
   TimeToStruct(TimeLocal(),dt);
   return dt.hour*60+dt.min;
}

bool InOneWindow(int nowMin,const string st,const string en,bool use)
{
   if(!use) return false;
   int hs,ms,he,me;
   if(!ParseHHMM(st,hs,ms) || !ParseHHMM(en,he,me)) return false;
   int a=hs*60+ms;
   int b=he*60+me;
   if(a<=b)
      return (nowMin>=a && nowMin<b);
   return (nowMin>=a || nowMin<b);
}

bool InAnySession()
{
   if(!UseMasterTimeFilter) return true;
   int n=MinutesNowLocal();
   if(InOneWindow(n,Win1_Start,Win1_End,UseWindow1)) return true;
   if(InOneWindow(n,Win2_Start,Win2_End,UseWindow2)) return true;
   if(InOneWindow(n,Win3_Start,Win3_End,UseWindow3)) return true;
   if(InOneWindow(n,Win4_Start,Win4_End,UseWindow4)) return true;
   return false;
}

//====================================================================
ENUM_TIMEFRAMES TFOrCurrent(ENUM_TIMEFRAMES tf)
{
   if(tf==PERIOD_CURRENT) return Period();
   return tf;
}

//====================================================================
bool Copy1(double &buf[],int handle,int shift,int count=3)
{
   ArraySetAsSeries(buf,true);
   if(CopyBuffer(handle,0,shift,count,buf)<count) return false;
   return true;
}

bool PassEMA(const bool wantBuy)
{
   if(!UseEMAFilter) return true;
   double f[],s[];
   if(!Copy1(f,hEmaFast,0,3) || !Copy1(s,hEmaSlow,0,3)) return false;

   const bool onCloseSignal=(EntryTiming==ENTRY_TIMING_CLOSE_SIGNAL);
   const int  iTrend=(onCloseSignal?0:1);

   if(EntrySignal==ENTRY_EMA_CROSS)
   {
      if(onCloseSignal)
      {
         if(wantBuy) return (f[1]<=s[1] && f[0]>s[0]);
         return (f[1]>=s[1] && f[0]<s[0]);
      }
      if(wantBuy) return (f[2]<=s[2] && f[1]>s[1]);
      return (f[2]>=s[2] && f[1]<s[1]);
   }
   if(EntrySignal==ENTRY_EMA_TREND || EntrySignal==ENTRY_NONE)
   {
      if(wantBuy) return (f[iTrend]>s[iTrend]);
      return (f[iTrend]<s[iTrend]);
   }
   return false;
}

bool PassMACD(const bool wantBuy)
{
   if(!UseMACDFilter) return true;
   double m[],sig[];
   ArraySetAsSeries(m,true);
   ArraySetAsSeries(sig,true);
   if(CopyBuffer(hMacd,0,0,2,m)<2) return false;
   if(CopyBuffer(hMacd,1,0,2,sig)<2) return false;
   if(wantBuy) return (m[1]>sig[1]);
   return (m[1]<sig[1]);
}

bool PassCCI(const bool wantBuy)
{
   if(!UseCCIFilter) return true;
   double c[];
   if(!Copy1(c,hCci,0,2)) return false;
   if(wantBuy) return (c[1]<CciOverbought);
   return (c[1]>CciOversold);
}

// Kiểm tra EMA+MACD+CCI cho một phía; log khi logOnFail (dùng silent=false để chỉ hỏi có đạt không)
bool TryFiltersForSide(const bool wantBuy,const bool logOnFail)
{
   if(!PassEMA(wantBuy))
   {
      if(logOnFail && DetailedTradeLog)
         Print("[TVH] Không vào ",(wantBuy?"BUY":"SELL"),": EMA không đạt | signal=",EnumToString(EntrySignal),
               " | timing=",EnumToString(EntryTiming));
      return false;
   }
   if(!PassMACD(wantBuy))
   {
      if(logOnFail && DetailedTradeLog)
         Print("[TVH] Không vào ",(wantBuy?"BUY":"SELL"),": MACD filter không đạt");
      return false;
   }
   if(!PassCCI(wantBuy))
   {
      if(logOnFail && DetailedTradeLog)
         Print("[TVH] Không vào ",(wantBuy?"BUY":"SELL"),": CCI filter không đạt");
      return false;
   }
   return true;
}

//====================================================================
int CountOurPositions()
{
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol) continue;
      if(pos.Magic()!=(long)MagicNumber) continue;
      c++;
   }
   return c;
}

// Giống GoldPro SyncState: mất lệnh (đóng tay/SL sàn) → xóa SL/TP ẩo + box
void FindOurTicket()
{
   ulong prev=g_ticket;
   g_ticket=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol) continue;
      if(pos.Magic()!=(long)MagicNumber) continue;
      g_ticket=pos.Ticket();
      return;
   }
   if(prev>0)
   {
      if(DetailedTradeLog)
         Print("[TVH] SYNC | Hết vị thế EA (ticket trước #",prev,") — có thể đóng tay / SL-TP sàn / magic khác. Xóa Virt SL/TP + box.");
      g_virtSL=0.0;
      g_virtTP=0.0;
      g_trailArmed=false;
      g_trailRef=0.0;
      g_posOpenTime=0;
      g_loggedGraceTicket=0;
      DeleteSltpBoxObjects();
   }
   else
      g_posOpenTime=0;
}

//--------------------------------------------------------------------
void DeleteSltpBoxObjects()
{
   const string names[]=
   {
      "TVH_AT_EntryLine","TVH_AT_SLBox","TVH_AT_TPBox",
      "TVH_AT_LabDir","TVH_AT_LabEN","TVH_AT_LabSL","TVH_AT_LabTP"
   };
   for(int i=0;i<ArraySize(names);i++)
      if(ObjectFind(0,names[i])>=0) ObjectDelete(0,names[i]);
   ChartRedraw(0);
}

void TvhChartLabel(const string name,const string txt,const datetime t,const double price,const color clr)
{
   if(ObjectFind(0,name)>=0) ObjectDelete(0,name);
   ObjectCreate(0,name,OBJ_TEXT,0,t,price);
   ObjectSetString(0,name,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,8);
   ObjectSetString(0,name,OBJPROP_FONT,"Arial");
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
}

// Vẽ vùng SL / TP ẩo (Virt) — BUY: SL dưới entry, TP trên; SELL ngược lại
void DrawSltpBoxesOnChart(const bool isBuy,const double entry,const double sl,const double tp)
{
   if(!DrawSltpBoxes)
   {
      DeleteSltpBoxObjects();
      return;
   }

   DeleteSltpBoxObjects();

   datetime t1=iTime(_Symbol,PERIOD_CURRENT,1);
   datetime t2=iTime(_Symbol,PERIOD_CURRENT,0)+(datetime)PeriodSeconds(PERIOD_CURRENT)*BoxExtendBars;
   if(t1<=0) t1=TimeCurrent()-(datetime)PeriodSeconds(PERIOD_CURRENT)*5;
   if(t2<=t1) t2=t1+(datetime)PeriodSeconds(PERIOD_CURRENT)*MathMax(BoxExtendBars,10);

   ObjectCreate(0,"TVH_AT_EntryLine",OBJ_TREND,0,t1,entry,t2,entry);
   ObjectSetInteger(0,"TVH_AT_EntryLine",OBJPROP_COLOR,ColorBoxEntry);
   ObjectSetInteger(0,"TVH_AT_EntryLine",OBJPROP_WIDTH,1);
   ObjectSetInteger(0,"TVH_AT_EntryLine",OBJPROP_STYLE,STYLE_DASH);
   ObjectSetInteger(0,"TVH_AT_EntryLine",OBJPROP_RAY_RIGHT,false);
   ObjectSetInteger(0,"TVH_AT_EntryLine",OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,"TVH_AT_EntryLine",OBJPROP_HIDDEN,true);

   double slTop,slBot,tpTop,tpBot;
   if(isBuy)
   {
      slTop=entry; slBot=sl;
      if(tp>0.0) { tpTop=tp; tpBot=entry; }
      else { tpTop=entry; tpBot=entry; }
   }
   else
   {
      slTop=sl; slBot=entry;
      if(tp>0.0) { tpTop=entry; tpBot=tp; }
      else { tpTop=entry; tpBot=entry; }
   }

   ObjectCreate(0,"TVH_AT_SLBox",OBJ_RECTANGLE,0,t1,slTop,t2,slBot);
   ObjectSetInteger(0,"TVH_AT_SLBox",OBJPROP_COLOR,ColorBoxSL);
   ObjectSetInteger(0,"TVH_AT_SLBox",OBJPROP_FILL,true);
   ObjectSetInteger(0,"TVH_AT_SLBox",OBJPROP_BACK,true);
   ObjectSetInteger(0,"TVH_AT_SLBox",OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,"TVH_AT_SLBox",OBJPROP_HIDDEN,true);

   if(tp>0.0)
   {
      ObjectCreate(0,"TVH_AT_TPBox",OBJ_RECTANGLE,0,t1,tpTop,t2,tpBot);
      ObjectSetInteger(0,"TVH_AT_TPBox",OBJPROP_COLOR,ColorBoxTP);
      ObjectSetInteger(0,"TVH_AT_TPBox",OBJPROP_FILL,true);
      ObjectSetInteger(0,"TVH_AT_TPBox",OBJPROP_BACK,true);
      ObjectSetInteger(0,"TVH_AT_TPBox",OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,"TVH_AT_TPBox",OBJPROP_HIDDEN,true);
   }

   string dirTxt=isBuy?"▲ BUY Virt":"▼ SELL Virt";
   color  dirClr=isBuy?clrLime:clrTomato;
   TvhChartLabel("TVH_AT_LabDir",dirTxt,t1,entry,dirClr);
   TvhChartLabel("TVH_AT_LabEN","Entry "+DoubleToString(entry,_Digits),t2,entry,ColorBoxEntry);
   TvhChartLabel("TVH_AT_LabSL","SL "+DoubleToString(sl,_Digits),t2,sl,ColorBoxSL);
   if(tp>0.0)
      TvhChartLabel("TVH_AT_LabTP","TP "+DoubleToString(tp,_Digits),t2,tp,ColorBoxTP);

   ChartRedraw(0);
}

//====================================================================
void OpenBuy()
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   if(SltpMode==SLTP_MODE_SWING_RR)
   {
      double _sl,_tp;
      if(!ComputeSwingVirtLevels(true,ask,_sl,_tp))
      {
         Print("TVH BUY: swing SL/TP không hợp lệ (ASK=",ask,"), bỏ qua lệnh");
         return;
      }
   }
   // FIXED_POINTS / PIPS: không cần kiểm tra trước khi gửi lệnh
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   if(!trade.Buy(Lots,_Symbol,0,0,0,"TVH BUY"))
   {
      Print("Buy failed ",trade.ResultRetcodeDescription());
      return;
   }
   Sleep(100);
   FindOurTicket();
   if(g_ticket==0) return;
   if(!pos.SelectByTicket(g_ticket)) return;
   double e=pos.PriceOpen();
   double distSL=0.0;

   if(SltpMode==SLTP_MODE_SWING_RR)
   {
      if(!ComputeSwingVirtLevels(true,e,g_virtSL,g_virtTP))
      {
         Print("TVH BUY: sau khớp swing lỗi — fallback pip");
         double want=InitialStopLossPips*PipPrice();
         distSL=MathMax(want,MinVirtualSlDistance());
         g_virtSL=NormalizeDouble(e-distSL,_Digits);
         g_virtTP=(TakeProfitPips>0.0)?NormalizeDouble(e+TakeProfitPips*PipPrice(),_Digits):0.0;
      }
      else
         distSL=e-g_virtSL;
   }
   else if(SltpMode==SLTP_MODE_FIXED_POINTS)
   {
      ApplyFixedPointVirtLevels(true,e,distSL);
   }
   else
   {
      double want=InitialStopLossPips*PipPrice();
      distSL=MathMax(want,MinVirtualSlDistance());
      g_virtSL=NormalizeDouble(e-distSL,_Digits);
      g_virtTP=(TakeProfitPips>0.0)?NormalizeDouble(e+TakeProfitPips*PipPrice(),_Digits):0.0;
   }

   g_trailArmed=false;
   g_trailRef=0.0;
   SanitizeVirtualStopsAfterOpen(true,e);
   g_posOpenTime=TimeCurrent();
   DrawSltpBoxesOnChart(true,e,g_virtSL,g_virtTP);
   g_loggedGraceTicket=0;
   if(DetailedTradeLog)
   {
      string slGapTxt,tpGapTxt;
      if(SltpMode==SLTP_MODE_FIXED_POINTS)
      {
         int sc=(FixedPointsPerUsd>=1)?FixedPointsPerUsd:1000;
         slGapTxt=" (cách "+DoubleToString((e-g_virtSL)*(double)sc,1)+" pt/"+IntegerToString(sc)+"/USD)";
         if(g_virtTP>0.0)
            tpGapTxt=" (cách "+DoubleToString((g_virtTP-e)*(double)sc,1)+" pt/"+IntegerToString(sc)+"/USD)";
      }
      else
      {
         slGapTxt=" (cách "+DoubleToString((e-g_virtSL)/_Point,1)+" pt MT5)";
         if(g_virtTP>0.0)
            tpGapTxt=" (cách "+DoubleToString((g_virtTP-e)/_Point,1)+" pt MT5)";
      }
      Print("[TVH] MỞ BUY | ticket=",g_ticket," | ",EnumToString(SltpMode),
            " | entry=",DoubleToString(e,_Digits)," ask=",DoubleToString(ask,_Digits),
            " | VirtSL=",DoubleToString(g_virtSL,_Digits),slGapTxt,
            " | VirtTP=",DoubleToString(g_virtTP,_Digits),tpGapTxt,
            " | spreadPts=",SymbolInfoInteger(_Symbol,SYMBOL_SPREAD));
   }
   else
      Print("OPEN BUY ticket=",g_ticket," mode=",EnumToString(SltpMode)," entry=",e," virtSL=",g_virtSL," virtTP=",g_virtTP);
}

void OpenSell()
{
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(SltpMode==SLTP_MODE_SWING_RR)
   {
      double _sl,_tp;
      if(!ComputeSwingVirtLevels(false,bid,_sl,_tp))
      {
         Print("TVH SELL: swing SL/TP không hợp lệ (BID=",bid,"), bỏ qua lệnh");
         return;
      }
   }
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   if(!trade.Sell(Lots,_Symbol,0,0,0,"TVH SELL"))
   {
      Print("Sell failed ",trade.ResultRetcodeDescription());
      return;
   }
   Sleep(100);
   FindOurTicket();
   if(g_ticket==0) return;
   if(!pos.SelectByTicket(g_ticket)) return;
   double e=pos.PriceOpen();
   double distSL=0.0;

   if(SltpMode==SLTP_MODE_SWING_RR)
   {
      if(!ComputeSwingVirtLevels(false,e,g_virtSL,g_virtTP))
      {
         Print("TVH SELL: sau khớp swing lỗi — fallback pip");
         double want=InitialStopLossPips*PipPrice();
         distSL=MathMax(want,MinVirtualSlDistance());
         g_virtSL=NormalizeDouble(e+distSL,_Digits);
         g_virtTP=(TakeProfitPips>0.0)?NormalizeDouble(e-TakeProfitPips*PipPrice(),_Digits):0.0;
      }
      else
         distSL=g_virtSL-e;
   }
   else if(SltpMode==SLTP_MODE_FIXED_POINTS)
   {
      ApplyFixedPointVirtLevels(false,e,distSL);
   }
   else
   {
      double want=InitialStopLossPips*PipPrice();
      distSL=MathMax(want,MinVirtualSlDistance());
      g_virtSL=NormalizeDouble(e+distSL,_Digits);
      g_virtTP=(TakeProfitPips>0.0)?NormalizeDouble(e-TakeProfitPips*PipPrice(),_Digits):0.0;
   }

   g_trailArmed=false;
   g_trailRef=0.0;
   SanitizeVirtualStopsAfterOpen(false,e);
   g_posOpenTime=TimeCurrent();
   DrawSltpBoxesOnChart(false,e,g_virtSL,g_virtTP);
   g_loggedGraceTicket=0;
   if(DetailedTradeLog)
   {
      string slGapTxt,tpGapTxt;
      if(SltpMode==SLTP_MODE_FIXED_POINTS)
      {
         int sc=(FixedPointsPerUsd>=1)?FixedPointsPerUsd:1000;
         slGapTxt=" (cách "+DoubleToString((g_virtSL-e)*(double)sc,1)+" pt/"+IntegerToString(sc)+"/USD)";
         if(g_virtTP>0.0)
            tpGapTxt=" (cách "+DoubleToString((e-g_virtTP)*(double)sc,1)+" pt/"+IntegerToString(sc)+"/USD)";
      }
      else
      {
         slGapTxt=" (cách "+DoubleToString((g_virtSL-e)/_Point,1)+" pt MT5)";
         if(g_virtTP>0.0)
            tpGapTxt=" (cách "+DoubleToString((e-g_virtTP)/_Point,1)+" pt MT5)";
      }
      Print("[TVH] MỞ SELL | ticket=",g_ticket," | ",EnumToString(SltpMode),
            " | entry=",DoubleToString(e,_Digits)," bid=",DoubleToString(bid,_Digits),
            " | VirtSL=",DoubleToString(g_virtSL,_Digits),slGapTxt,
            " | VirtTP=",DoubleToString(g_virtTP,_Digits),tpGapTxt,
            " | spreadPts=",SymbolInfoInteger(_Symbol,SYMBOL_SPREAD));
   }
   else
      Print("OPEN SELL ticket=",g_ticket," mode=",EnumToString(SltpMode)," entry=",e," virtSL=",g_virtSL," virtTP=",g_virtTP);
}

//====================================================================
bool InExitGracePeriod()
{
   if(ExitGraceSeconds<=0 || g_posOpenTime<=0) return false;
   return ((TimeCurrent()-g_posOpenTime)<ExitGraceSeconds);
}

// Giống MonitorTrade trong BUY_ONLY_H4 / SELL_ONLY_H4: BUY dùng BID, SELL dùng ASK
void TvhMonitorTrade(const double bid,const double ask)
{
   if(g_ticket==0 || !pos.SelectByTicket(g_ticket))
      return;

   const bool isBuy=(pos.PositionType()==POSITION_TYPE_BUY);
   double entry=pos.PriceOpen();

   const bool skipSltp=(ExitGraceSeconds>0 && InExitGracePeriod());
   if(skipSltp && DetailedTradeLog && g_ticket!=g_loggedGraceTicket)
   {
      Print("[TVH] Grace ",ExitGraceSeconds,"s | ticket=",g_ticket," — chưa kiểm tra Virt SL/TP (chờ hết grace)");
      g_loggedGraceTicket=g_ticket;
   }

   if(!skipSltp)
   {
      if(isBuy)
      {
         if(g_virtTP>0.0 && bid>=g_virtTP)
         {
            if(DetailedTradeLog)
               Print("[TVH] ĐÓNG BUY | LÝ DO: Virt TP | ticket=",g_ticket,
                     " | BID=",DoubleToString(bid,_Digits)," >= VirtTP=",DoubleToString(g_virtTP,_Digits),
                     " | entry=",DoubleToString(entry,_Digits)," | trailArmed=",g_trailArmed);
            if(!TvhPositionCloseLogged(g_ticket,"BUY Virt TP")) return;
            g_ticket=0; g_posOpenTime=0; g_virtSL=0; g_virtTP=0; g_trailArmed=false; g_trailRef=0; g_loggedGraceTicket=0;
            DeleteSltpBoxObjects();
            return;
         }
         if(bid<=g_virtSL)
         {
            if(DetailedTradeLog)
               Print("[TVH] ĐÓNG BUY | LÝ DO: Virt SL (hoặc SL sau trail) | ticket=",g_ticket,
                     " | BID=",DoubleToString(bid,_Digits)," <= VirtSL=",DoubleToString(g_virtSL,_Digits),
                     " | entry=",DoubleToString(entry,_Digits)," | VirtTP=",DoubleToString(g_virtTP,_Digits),
                     " | trailArmed=",g_trailArmed);
            if(!TvhPositionCloseLogged(g_ticket,"BUY Virt SL")) return;
            g_ticket=0; g_posOpenTime=0; g_virtSL=0; g_virtTP=0; g_trailArmed=false; g_trailRef=0; g_loggedGraceTicket=0;
            DeleteSltpBoxObjects();
            return;
         }
      }
      else
      {
         if(g_virtTP>0.0 && ask<=g_virtTP)
         {
            if(DetailedTradeLog)
               Print("[TVH] ĐÓNG SELL | LÝ DO: Virt TP | ticket=",g_ticket,
                     " | ASK=",DoubleToString(ask,_Digits)," <= VirtTP=",DoubleToString(g_virtTP,_Digits),
                     " | entry=",DoubleToString(entry,_Digits)," | trailArmed=",g_trailArmed);
            if(!TvhPositionCloseLogged(g_ticket,"SELL Virt TP")) return;
            g_ticket=0; g_posOpenTime=0; g_virtSL=0; g_virtTP=0; g_trailArmed=false; g_trailRef=0; g_loggedGraceTicket=0;
            DeleteSltpBoxObjects();
            return;
         }
         if(ask>=g_virtSL)
         {
            if(DetailedTradeLog)
               Print("[TVH] ĐÓNG SELL | LÝ DO: Virt SL (hoặc SL sau trail) | ticket=",g_ticket,
                     " | ASK=",DoubleToString(ask,_Digits)," >= VirtSL=",DoubleToString(g_virtSL,_Digits),
                     " | entry=",DoubleToString(entry,_Digits)," | VirtTP=",DoubleToString(g_virtTP,_Digits),
                     " | trailArmed=",g_trailArmed);
            if(!TvhPositionCloseLogged(g_ticket,"SELL Virt SL")) return;
            g_ticket=0; g_posOpenTime=0; g_virtSL=0; g_virtTP=0; g_trailArmed=false; g_trailRef=0; g_loggedGraceTicket=0;
            DeleteSltpBoxObjects();
            return;
         }
      }
   }

   bool mayTrail=(ManageOutsideSessions || InAnySession());
   if(!UseVirtTrailing || !mayTrail)
   {
      DrawSltpBoxesOnChart(isBuy,entry,g_virtSL,g_virtTP);
      return;
   }

   if(isBuy)
   {
      double prof=bid-entry;
      if(!g_trailArmed)
      {
         if(prof>=FirstTrailPips*PipPrice())
         {
            g_trailArmed=true;
            g_virtSL=NormalizeDouble(entry,_Digits);
            g_trailRef=entry+FirstTrailPips*PipPrice();
            Print("TRAIL ARMED BUY | BE SL | ref=",g_trailRef);
         }
      }
      else
      {
         while(bid>=g_trailRef+TrailStepPips*PipPrice())
         {
            g_trailRef+=TrailStepPips*PipPrice();
            g_virtSL=NormalizeDouble(g_virtSL+TrailStepPips*PipPrice(),_Digits);
            if(g_virtSL>=bid) g_virtSL=NormalizeDouble(bid-MinVirtualSlDistance(),_Digits);
            Print("TRAIL STEP BUY | SL=",g_virtSL," ref=",g_trailRef);
         }
      }
   }
   else
   {
      double prof=entry-ask;
      if(!g_trailArmed)
      {
         if(prof>=FirstTrailPips*PipPrice())
         {
            g_trailArmed=true;
            g_virtSL=NormalizeDouble(entry,_Digits);
            g_trailRef=entry-FirstTrailPips*PipPrice();
            Print("TRAIL ARMED SELL | BE SL | ref=",g_trailRef);
         }
      }
      else
      {
         while(ask<=g_trailRef-TrailStepPips*PipPrice())
         {
            g_trailRef-=TrailStepPips*PipPrice();
            g_virtSL=NormalizeDouble(g_virtSL-TrailStepPips*PipPrice(),_Digits);
            if(g_virtSL<=ask) g_virtSL=NormalizeDouble(ask+MinVirtualSlDistance(),_Digits);
            Print("TRAIL STEP SELL | SL=",g_virtSL," ref=",g_trailRef);
         }
      }
   }

   DrawSltpBoxesOnChart(isBuy,entry,g_virtSL,g_virtTP);
}

//====================================================================
bool TvhPositionCloseLogged(const ulong ticket,const string reason)
{
   if(!trade.PositionClose(ticket))
   {
      if(DetailedTradeLog)
         Print("[TVH] LỖI PositionClose #",ticket," | ",reason," | ",trade.ResultRetcode()," ",trade.ResultComment());
      return false;
   }
   return true;
}

//====================================================================
void TryEnter()
{
   if(CountOurPositions()>=MaxPositions)
   {
      if(DetailedTradeLog)
         Print("[TVH] Không tìm vào lệnh: đã có ",CountOurPositions()," vị thế (MaxPositions=",MaxPositions,")");
      return;
   }
   if(UseMasterTimeFilter && !InAnySession()) return;

   ENUM_TIMEFRAMES tf=TFOrCurrent(EntryTF);
   datetime bar=iTime(_Symbol,tf,0);

   if(EntryTiming==ENTRY_TIMING_NEW_BAR)
   {
      if(bar==g_lastEntryEvalBar) return;
      g_lastEntryEvalBar=bar;
      if(DetailedTradeLog)
      {
         string h=(TradeSide==SIDE_BUY_ONLY?"BUY":(TradeSide==SIDE_SELL_ONLY?"SELL":"BUY+SELL"));
         Print("[TVH] --- Xét vào lệnh (NEW_BAR) | bar ",TimeToString(bar,TIME_DATE|TIME_MINUTES),
               " | ",EnumToString(tf)," | hướng ",h);
      }
   }
   else
   {
      if(bar==g_firedSignalBar) return;
   }

   bool wantBuy=false;
   bool loggedBothPriority=false;
   if(TradeSide==SIDE_BUY_ONLY)
   {
      if(!TryFiltersForSide(true,true)) return;
      wantBuy=true;
   }
   else if(TradeSide==SIDE_SELL_ONLY)
   {
      if(!TryFiltersForSide(false,true)) return;
      wantBuy=false;
   }
   else
   {
      const bool okBuy =TryFiltersForSide(true,false);
      const bool okSell=TryFiltersForSide(false,false);
      if(!okBuy && !okSell)
      {
         if(DetailedTradeLog)
            Print("[TVH] Không vào (BUY+SELL): cả hai phía đều không đủ filter — chi tiết:");
         TryFiltersForSide(true,true);
         TryFiltersForSide(false,true);
         return;
      }
      if(okBuy && !okSell)
         wantBuy=true;
      else if(!okBuy && okSell)
         wantBuy=false;
      else
      {
         wantBuy=(BothSignalsPriority==BOTH_PRIO_BUY_FIRST);
         if(DetailedTradeLog)
         {
            Print("[TVH] BUY+SELL: cả hai phía đủ filter → mở ",(wantBuy?"BUY":"SELL"),
                  " (ưu tiên ",EnumToString(BothSignalsPriority),")");
            loggedBothPriority=true;
         }
      }
   }

   if(DetailedTradeLog && !loggedBothPriority)
      Print("[TVH] Đủ điều kiện filter → gửi lệnh ",(wantBuy?"BUY":"SELL"),"...");

   int npos=CountOurPositions();
   if(wantBuy) OpenBuy();
   else        OpenSell();
   if(EntryTiming==ENTRY_TIMING_CLOSE_SIGNAL && CountOurPositions()>npos)
   {
      g_firedSignalBar=bar;
      if(DetailedTradeLog)
         Print("[TVH] CLOSE_SIGNAL: đã đánh dấu bar ",TimeToString(bar,TIME_DATE|TIME_MINUTES)," (1 lần/nến)");
   }
}

//====================================================================
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   ENUM_TIMEFRAMES etf=TFOrCurrent(EmaTF);
   ENUM_TIMEFRAMES mtf=TFOrCurrent(MacdTF);
   ENUM_TIMEFRAMES ctf=TFOrCurrent(CciTF);

   hEmaFast=iMA(_Symbol,etf,EmaFastPeriod,0,MODE_EMA,EmaApplied);
   hEmaSlow=iMA(_Symbol,etf,EmaSlowPeriod,0,MODE_EMA,EmaApplied);
   if(UseMACDFilter)
      hMacd=iMACD(_Symbol,mtf,MacdFast,MacdSlow,MacdSignal,MacdApplied);
   if(UseCCIFilter)
      hCci=iCCI(_Symbol,ctf,CciPeriod,CciApplied);

   if(hEmaFast==INVALID_HANDLE || hEmaSlow==INVALID_HANDLE)
   {
      Print("EMA handle fail");
      return INIT_FAILED;
   }
   if(UseMACDFilter && hMacd==INVALID_HANDLE) { Print("MACD fail"); return INIT_FAILED; }
   if(UseCCIFilter && hCci==INVALID_HANDLE) { Print("CCI fail"); return INIT_FAILED; }

   FindOurTicket();
   if(g_ticket>0)
      RestoreVirtLevelsForOpenPosition();
   Print("TVH_AUTO_TRADE | ",_Symbol," | Magic=",MagicNumber," | Sltp=",EnumToString(SltpMode),
         " | TradeSide=",EnumToString(TradeSide));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   DeleteSltpBoxObjects();
   if(hEmaFast!=INVALID_HANDLE) IndicatorRelease(hEmaFast);
   if(hEmaSlow!=INVALID_HANDLE) IndicatorRelease(hEmaSlow);
   if(hMacd!=INVALID_HANDLE) IndicatorRelease(hMacd);
   if(hCci!=INVALID_HANDLE) IndicatorRelease(hCci);
}

void OnTick()
{
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);

   FindOurTicket();

   if(g_ticket>0)
      TvhMonitorTrade(bid,ask);

   if(g_ticket==0 && (!UseMasterTimeFilter || InAnySession()))
      TryEnter();

   string timingLbl=(EntryTiming==ENTRY_TIMING_NEW_BAR)?"NEW_BAR (như Sell OPEN_NEXT_BAR)":"CLOSE_SIGNAL (như Sell CLOSE_SIGNAL)";
   string sltpLbl;
   if(SltpMode==SLTP_MODE_SWING_RR)
      sltpLbl="SWING+RR L="+IntegerToString(SwingLookback)+" RR="+DoubleToString(RiskReward,1);
   else if(SltpMode==SLTP_MODE_FIXED_POINTS)
     {
      int scLbl=(FixedPointsPerUsd>=1)?FixedPointsPerUsd:1000;
      sltpLbl="FIXED SL="+IntegerToString(StopLossPoints)+" TP="+IntegerToString(TakeProfitPoints)+
              " | "+IntegerToString(scLbl)+"pt=1.0giá";
     }
   else
      sltpLbl="PIP SL="+DoubleToString(InitialStopLossPips,1)+" TP="+DoubleToString(TakeProfitPips,1)+" PPP="+IntegerToString(PointsPerPip);
   string sess=InAnySession()?"Trong phiên":"Ngoài phiên";
   string sideLbl;
   if(g_ticket>0 && pos.SelectByTicket(g_ticket))
      sideLbl=(pos.PositionType()==POSITION_TYPE_BUY)?"BUY":"SELL";
   else if(TradeSide==SIDE_BUY_ONLY)
      sideLbl="BUY";
   else if(TradeSide==SIDE_SELL_ONLY)
      sideLbl="SELL";
   else
      sideLbl="BUY+SELL";
   string posTxt=(g_ticket>0)?("Ticket "+(string)g_ticket+" | "+sideLbl):("Không lệnh");
   string grace="—";
   if(g_ticket>0)
   {
      if(ExitGraceSeconds<=0) grace="Tắt";
      else if(InExitGracePeriod()) grace="Có ("+(string)(ExitGraceSeconds-(int)(TimeCurrent()-g_posOpenTime))+"s)";
      else grace="Hết";
   }
   Comment(
      "TVH_AUTO_TRADE — luồng như BUY/SELL_ONLY_H4 (MonitorTrade)\n",
      "Hướng: ",(TradeSide==SIDE_BUY_AND_SELL?"BUY+SELL (ưu tiên "+EnumToString(BothSignalsPriority)+")":
      (TradeSide==SIDE_BUY_ONLY?"BUY only":"SELL only")),"\n",
      "SL/TP: ",sltpLbl," | SwingTF=",EnumToString(SwingTF),"\n",
      "Vào: ",timingLbl," | EMA theo EntryTiming; MACD/CCI [1].\n",
      "Đóng: BUY=BID vs SL/TP ẩo | SELL=ASK vs SL/TP ẩo.\n",
      "Trail ảo: ",(UseVirtTrailing?"BẬT":"TẮT")," | Thoát: SL/TP ẩo",(UseVirtTrailing?" hoặc trail":""),".\n",
      "Grace ",ExitGraceSeconds,"s: không đóng theo Virt SL/TP ngay sau khi mở.\n",
      "---\n",
      sess," | ",posTxt,"\n",
      "Virt SL: ",g_virtSL," | Virt TP: ",g_virtTP,"\n",
      "Trail armed: ",(g_trailArmed?"Có":"Không")," | Grace: ",grace
   );
}

//+------------------------------------------------------------------+

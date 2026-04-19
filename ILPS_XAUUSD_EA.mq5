//+------------------------------------------------------------------+
//|  Institutional Liquidity Precision System (ILPS)                 |
//|  XAUUSD HFT Expert Advisor for MetaTrader 5                      |
//|  Strategy designed by: Quantitative Strategy Framework           |
//|  Version: 1.0.0                                                  |
//|                                                                  |
//|  TIMEFRAMES USED:                                                |
//|    H1  - Structural Bias (BOS)                                   |
//|    M15 - Liquidity Pool Identification                           |
//|    M5  - FVG Detection + ATR Filter                              |
//|    M1  - CHoCH Confirmation + Entry Execution                    |
//+------------------------------------------------------------------+
#property copyright   "ILPS Strategy"
#property version     "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//-------------------------------------------------------------------
// INPUT PARAMETERS
//-------------------------------------------------------------------

input group "=== SESSION SETTINGS ==="
input int    LondonOpenHour      = 7;    // London Open Hour (GMT)
input int    LondonCloseHour     = 9;    // London Session End Hour (GMT)
input int    LondonCloseMin      = 30;   // London Session End Minute
input int    NYOpenHour          = 12;   // NY Overlap Start Hour (GMT)
input int    NYCloseHour         = 15;   // NY Overlap End Hour (GMT)
input int    NYCloseMin          = 30;   // NY Overlap End Minute

input group "=== RISK MANAGEMENT ==="
input double BaseRiskPercent     = 0.5;  // Base risk per trade (%)
input double APlusRiskPercent    = 1.0;  // A+ setup risk per trade (%)
input double MaxDailyLossPct     = 3.0;  // Max daily loss (%)
input double MaxWeeklyLossPct    = 6.0;  // Max weekly loss (%)
input double RecoveryDrawdownPct = 10.0; // Drawdown % to trigger recovery mode
input int    MaxTradesPerDay     = 5;    // Max trades per day
input int    MaxLondonTrades     = 3;    // Max trades in London session
input int    MaxNYTrades         = 2;    // Max trades in NY session

input group "=== LOSS STREAK HANDLING ==="
input int    PauseTrades2        = 2;    // Reduce lots after X consecutive losses
input int    PauseTrades3        = 3;    // Pause 1 session after X losses
input int    PauseTrades4        = 4;    // Pause day after X losses
input int    PauseTrades5        = 5;    // Pause 24h after X losses

input group "=== STRATEGY PARAMETERS ==="
input double MaxSpreadPips       = 25.0; // Max allowed spread (pips)
input double CrisisSpreadPips    = 40.0; // Crisis spread - close all (pips)
input double MinSLPips           = 8.0;  // Minimum SL distance (pips)
input double MaxSLPips           = 20.0; // Maximum SL distance (pips)
input double SweepMinPips        = 2.0;  // Min sweep beyond pool (pips)
input double SweepMaxPips        = 15.0; // Max sweep beyond pool (pips)
input double LiqPoolTolPips      = 3.0;  // Liquidity pool tolerance (pips)
input double FVGPoolMaxDist      = 20.0; // Max FVG distance from pool (pips)
input double MinATRPips          = 8.0;  // Min ATR for active market
input double MarginalATRPips     = 5.0;  // Marginal ATR (A+ only)
input int    ATRPeriod           = 14;   // ATR period
input int    SwingLookback       = 5;    // Bars each side for swing detection
input int    MaxFVGStore         = 20;   // Max FVGs to track
input int    MaxLiqPools         = 10;   // Max liquidity pools to track
input int    CHoCHTimeout        = 5;    // M1 candles before sweep invalidates
input int    MaxTradeMinutes     = 45;   // Max trade duration (minutes)
input int    NewsBufferMinutes   = 15;   // Minutes before/after news to avoid

input group "=== TAKE PROFIT / STOP LOSS ==="
input double TP1_RR              = 1.0;  // TP1 Risk:Reward ratio
input double TP2_RR              = 2.0;  // TP2 Risk:Reward ratio
input double TP3_RR              = 3.0;  // TP3 Risk:Reward ratio
input double TP1_ClosePct        = 40.0; // % of position to close at TP1
input double TP2_ClosePct        = 35.0; // % of position to close at TP2
input double TrailStopPips       = 10.0; // Trailing stop for TP3 runner (pips)
input int    SweepWickBuffer     = 3;    // Extra pips beyond sweep wick for SL

input group "=== DISPLAY & LOGGING ==="
input bool   ShowDashboard       = true; // Show info dashboard on chart
input bool   EnableAlerts        = true; // Enable alerts
input bool   VerboseLogging      = false;// Verbose logging to journal
input color  BullColor           = clrDodgerBlue;  // Bullish zone color
input color  BearColor           = clrCrimson;     // Bearish zone color
input color  FVGColor            = clrGold;        // FVG zone color
input string EAMagicComment      = "ILPS_EA";      // Order comment

input group "=== NEWS FILTER (UTC TIMES) ==="
// High-impact events: format "MMDD-HH:MM" e.g., "0101-14:00"
// Add up to 10 events manually here for the current week
input string NewsEvent1          = "";  // News event 1 (MMDD-HH:MM)
input string NewsEvent2          = "";  // News event 2
input string NewsEvent3          = "";  // News event 3
input string NewsEvent4          = "";  // News event 4
input string NewsEvent5          = "";  // News event 5

//-------------------------------------------------------------------
// GLOBAL VARIABLES
//-------------------------------------------------------------------

// Trade management
CTrade         trade;
CPositionInfo  posInfo;
COrderInfo     orderInfo;

// Magic number for this EA
int  MAGIC_NUMBER  = 20240101;
long AccountNumber = 0;

// Pip value for XAUUSD
double PipSize     = 0.1;   // XAUUSD: 1 pip = $0.10 per 0.01 lot
double PointSize   = 0.01;  // XAUUSD point

// Session tracking
int    TradesToday         = 0;
int    LondonTradesToday   = 0;
int    NYTradesToday       = 0;
double DailyLossUsed       = 0.0;
double WeeklyLossUsed      = 0.0;
double PeakEquity          = 0.0;
double SessionStartEquity  = 0.0;
datetime LastDayChecked    = 0;
datetime LastWeekChecked   = 0;
bool   TradingHalted       = false;
bool   RecoveryMode        = false;
datetime PauseUntil        = 0;

// Consecutive loss tracking
int    ConsecutiveLosses   = 0;
int    ConsecutiveWins     = 0;

// Market structure
enum ENUM_BOS_DIRECTION { BOS_NONE, BOS_BULL, BOS_BEAR };
ENUM_BOS_DIRECTION CurrentBOS = BOS_NONE;

// Liquidity pools
struct LiquidityPool
{
   double   price;
   bool     isBSL;      // true = Buy-Side Liq, false = Sell-Side Liq
   bool     consumed;
   datetime created;
};
LiquidityPool LiqPools[];
int LiqPoolCount = 0;

// Fair Value Gaps
struct FVGZone
{
   double   high;
   double   low;
   double   mid;
   bool     isBullish;
   bool     mitigated;
   datetime created;
};
FVGZone FVGZones[];
int FVGCount = 0;

// Sweep tracking
bool     SweepLongConfirmed  = false;
bool     SweepShortConfirmed = false;
double   SweepWickExtreme    = 0.0;   // The wick low (long) or high (short)
datetime SweepTime           = 0;
int      SweepCandleCount    = 0;     // M1 candles since sweep

// CHoCH tracking
bool     CHoCHLong           = false;
bool     CHoCHShort          = false;
double   PostSweepSwingRef   = 0.0;   // Swing high (long) or low (short) to break

// Open trade management
bool     TP1Hit              = false;
bool     TP2Hit              = false;
bool     TrailingActive      = false;
double   EntryPrice          = 0.0;
double   CurrentSL           = 0.0;
double   InitialSLPrice      = 0.0;
double   SLPipsDistance      = 0.0;
datetime TradeOpenTime       = 0;
int      LastTradeDirection  = 0;     // 1=long, -1=short

// ATR
double   CurrentATR_M5       = 0.0;
double   ATRAverage5         = 0.0;

// News events
datetime NewsEvents[];
int      NewsEventCount = 0;

// H1 bars for BOS
datetime LastH1BarTime  = 0;
datetime LastM5BarTime  = 0;
datetime LastM1BarTime  = 0;
datetime LastM15BarTime = 0;

// Dashboard label names
string   LabelPrefix = "ILPS_";

// Tick volumes
long     LastSweepVolume = 0;

//-------------------------------------------------------------------
// UTILITY STRUCTURES
//-------------------------------------------------------------------

struct SwingPoint
{
   double   price;
   int      barIndex;
   datetime time;
   bool     isHigh;
};

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Validate symbol
   if(Symbol() != "XAUUSD" && Symbol() != "XAUUSDm" && Symbol() != "GOLD")
      Print("WARNING: This EA is optimized for XAUUSD. Current symbol: ", Symbol());

   // Set pip size based on symbol digits
   PointSize = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   // XAUUSD: typically 2 digits, point = 0.01
   // Pip = 10 * point for most gold brokers
   if(Digits() == 2)      PipSize = PointSize * 10;
   else if(Digits() == 3) PipSize = PointSize * 10;
   else                   PipSize = PointSize * 10;

   // Configure trade object
   trade.SetExpertMagicNumber(MAGIC_NUMBER);
   trade.SetDeviationInPoints(30);  // 3 pips slippage allowance
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   trade.SetAsyncMode(true);  // Use async for lower latency

   // Initialize arrays
   ArrayResize(LiqPools, MaxLiqPools);
   ArrayResize(FVGZones, MaxFVGStore);
   ArrayResize(NewsEvents, 10);

   // Account tracking
   AccountNumber = AccountInfoInteger(ACCOUNT_LOGIN);
   PeakEquity    = AccountInfoDouble(ACCOUNT_EQUITY);
   SessionStartEquity = PeakEquity;

   // Parse news events from input
   ParseNewsEvents();

   // Initial structural scan
   ScanH1BOS();
   ScanM15LiquidityPools();
   ScanM5FVGs();

   // Draw dashboard
   if(ShowDashboard) DrawDashboard();

   Print("ILPS EA Initialized | Account: ", AccountNumber,
         " | Symbol: ", Symbol(),
         " | PipSize: ", PipSize);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Remove dashboard objects
   if(ShowDashboard) RemoveDashboard();
   // Remove drawn zones
   ObjectsDeleteAll(0, LabelPrefix);
   Print("ILPS EA Deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function (main logic)                                 |
//+------------------------------------------------------------------+
void OnTick()
{
   // -----------------------------------------------------------
   // STEP 0: Daily/Weekly Reset
   // -----------------------------------------------------------
   CheckDailyReset();
   CheckWeeklyReset();

   // -----------------------------------------------------------
   // STEP 1: Crisis spread check (always runs)
   // -----------------------------------------------------------
   double spreadPips = GetSpreadPips();
   if(spreadPips >= CrisisSpreadPips)
   {
      CloseAllPositions("CRISIS_SPREAD");
      return;
   }

   // -----------------------------------------------------------
   // STEP 2: Bar-close recalculations
   // -----------------------------------------------------------
   bool newH1Bar  = IsNewBar(PERIOD_H1,  LastH1BarTime);
   bool newM15Bar = IsNewBar(PERIOD_M15, LastM15BarTime);
   bool newM5Bar  = IsNewBar(PERIOD_M5,  LastM5BarTime);
   bool newM1Bar  = IsNewBar(PERIOD_M1,  LastM1BarTime);

   if(newH1Bar)
   {
      ScanH1BOS();
      if(VerboseLogging) Print("H1 BOS updated: ", EnumToString(CurrentBOS));
   }
   if(newM15Bar)
   {
      ScanM15LiquidityPools();
      if(VerboseLogging) Print("M15 Liquidity pools updated. Count: ", LiqPoolCount);
   }
   if(newM5Bar)
   {
      ScanM5FVGs();
      CalcATR();
      if(VerboseLogging) Print("M5 FVGs updated. Count: ", FVGCount, " | ATR: ", CurrentATR_M5);
   }

   // -----------------------------------------------------------
   // STEP 3: Open trade management (runs every tick)
   // -----------------------------------------------------------
   if(HasOpenPosition())
   {
      ManageOpenTrade();
      if(ShowDashboard) UpdateDashboard();
      return; // Do not look for new entries while in a trade
   }

   // -----------------------------------------------------------
   // STEP 4: Pre-entry filters (run every tick)
   // -----------------------------------------------------------
   if(TradingHalted)
   {
      if(TimeCurrent() < PauseUntil)
      {
         if(ShowDashboard) UpdateDashboard();
         return;
      }
      else
      {
         TradingHalted = false;
         Print("ILPS: Trading resumed.");
      }
   }

   // RULE T-1: Session window
   if(!IsInTradingSession()) { if(ShowDashboard) UpdateDashboard(); return; }

   // RULE T-2: News blackout
   if(IsNewsBlackout()) { if(ShowDashboard) UpdateDashboard(); return; }

   // RULE T-3: Spread check
   if(spreadPips > MaxSpreadPips) { if(ShowDashboard) UpdateDashboard(); return; }

   // RULE T-4: Daily exposure
   if(TradesToday >= MaxTradesPerDay) { if(ShowDashboard) UpdateDashboard(); return; }
   if(DailyLossUsed >= (AccountInfoDouble(ACCOUNT_BALANCE) * MaxDailyLossPct / 100.0))
   {
      TradingHalted = true;
      PauseUntil = GetEndOfDay();
      Print("ILPS: Daily loss limit hit. Trading halted.");
      if(ShowDashboard) UpdateDashboard();
      return;
   }

   // RULE T-5: Consecutive losses
   if(!CheckLossStreak()) { if(ShowDashboard) UpdateDashboard(); return; }

   // RULE T-6: Volatility gate
   CalcATR();
   if(CurrentATR_M5 < MarginalATRPips * PipSize) { if(ShowDashboard) UpdateDashboard(); return; }

   // RULE T-7: Directional bias
   if(CurrentBOS == BOS_NONE) { if(ShowDashboard) UpdateDashboard(); return; }

   // -----------------------------------------------------------
   // STEP 5: On new M1 bar — sweep + CHoCH detection
   // -----------------------------------------------------------
   if(newM1Bar)
   {
      if(SweepLongConfirmed || SweepShortConfirmed)
      {
         SweepCandleCount++;
         if(SweepCandleCount > CHoCHTimeout)
         {
            // Sweep expired — invalidate
            ResetSweepState();
            if(VerboseLogging) Print("ILPS: Sweep invalidated (CHoCH timeout).");
         }
         else
         {
            // Update post-sweep swing reference
            UpdatePostSweepSwing();
         }
      }
   }

   // RULE T-8: Liquidity sweep detection (every tick)
   if(!SweepLongConfirmed && !SweepShortConfirmed)
      DetectLiquiditySweep();

   // RULE T-10: CHoCH detection (every tick after sweep)
   if(SweepLongConfirmed || SweepShortConfirmed)
      DetectCHoCH();

   // -----------------------------------------------------------
   // STEP 6: If CHoCH confirmed — validate full confluence
   // -----------------------------------------------------------
   if(CHoCHLong || CHoCHShort)
   {
      EvaluateAndEnter();
   }

   if(ShowDashboard) UpdateDashboard();
}

//+------------------------------------------------------------------+
//| BAR CLOSE DETECTION                                              |
//+------------------------------------------------------------------+
bool IsNewBar(ENUM_TIMEFRAMES timeframe, datetime &lastTime)
{
   datetime barTime = iTime(Symbol(), timeframe, 0);
   if(barTime != lastTime)
   {
      lastTime = barTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| H1 BREAK OF STRUCTURE DETECTION                                  |
//+------------------------------------------------------------------+
void ScanH1BOS()
{
   int barsNeeded = 50 + SwingLookback * 2;
   MqlRates h1Rates[];
   ArraySetAsSeries(h1Rates, true);
   int copied = CopyRates(Symbol(), PERIOD_H1, 0, barsNeeded, h1Rates);
   if(copied < 20) return;

   // Find most recent swing highs and lows with lookback
   double lastSwingHigh = 0, lastSwingLow = DBL_MAX;
   int    lastSwingHighBar = -1, lastSwingLowBar = -1;

   // Scan from recent bars backward
   for(int i = SwingLookback; i < copied - SwingLookback; i++)
   {
      bool isSwingHigh = true;
      bool isSwingLow  = true;
      for(int j = 1; j <= SwingLookback; j++)
      {
         if(h1Rates[i].high <= h1Rates[i-j].high || h1Rates[i].high <= h1Rates[i+j].high)
            isSwingHigh = false;
         if(h1Rates[i].low >= h1Rates[i-j].low || h1Rates[i].low >= h1Rates[i+j].low)
            isSwingLow = false;
      }
      if(isSwingHigh && lastSwingHighBar == -1)
      {
         lastSwingHigh    = h1Rates[i].high;
         lastSwingHighBar = i;
      }
      if(isSwingLow && lastSwingLowBar == -1)
      {
         lastSwingLow    = h1Rates[i].low;
         lastSwingLowBar = i;
      }
      if(lastSwingHighBar != -1 && lastSwingLowBar != -1) break;
   }

   if(lastSwingHighBar == -1 || lastSwingLowBar == -1) return;

   // Current bar close
   double currentClose = h1Rates[0].close;

   // BOS Bull: current close > last swing high (closed above, not just wick)
   if(currentClose > lastSwingHigh && lastSwingLowBar < lastSwingHighBar)
      CurrentBOS = BOS_BULL;
   // BOS Bear: current close < last swing low
   else if(currentClose < lastSwingLow && lastSwingHighBar < lastSwingLowBar)
      CurrentBOS = BOS_BEAR;
   // If no clear BOS, keep previous
}

//+------------------------------------------------------------------+
//| M15 LIQUIDITY POOL IDENTIFICATION                                |
//+------------------------------------------------------------------+
void ScanM15LiquidityPools()
{
   // Reset pools
   LiqPoolCount = 0;
   for(int _k=0;_k<MaxLiqPools;_k++){LiqPools[_k].price=0;LiqPools[_k].isBSL=false;LiqPools[_k].consumed=false;LiqPools[_k].created=0;}

   MqlRates m15Rates[];
   ArraySetAsSeries(m15Rates, true);
   // Get Asian session bars (approx last 7 hours = 28 M15 bars, plus buffer)
   int copied = CopyRates(Symbol(), PERIOD_M15, 0, 60, m15Rates);
   if(copied < 10) return;

   // Find Asian session start/end in current bars
   // Asian session = 00:00 to 07:00 GMT
   // We look for equal highs/lows within LiqPoolTolPips tolerance

   double swingHighs[], swingLows[];
   datetime swingHighTimes[], swingLowTimes[];
   int highCount = 0, lowCount = 0;
   ArrayResize(swingHighs, 30);
   ArrayResize(swingLows, 30);
   ArrayResize(swingHighTimes, 30);
   ArrayResize(swingLowTimes, 30);

   for(int i = SwingLookback; i < copied - SwingLookback; i++)
   {
      // Only consider Asian session bars
      MqlDateTime dt;
      TimeToStruct(m15Rates[i].time, dt);
      int hourGMT = dt.hour;
      if(hourGMT < 0 || hourGMT >= 7) continue;

      bool isSwingHigh = true, isSwingLow = true;
      for(int j = 1; j <= SwingLookback; j++)
      {
         if(i-j < 0 || i+j >= copied) { isSwingHigh = false; isSwingLow = false; break; }
         if(m15Rates[i].high <= m15Rates[i-j].high || m15Rates[i].high <= m15Rates[i+j].high)
            isSwingHigh = false;
         if(m15Rates[i].low >= m15Rates[i-j].low || m15Rates[i].low >= m15Rates[i+j].low)
            isSwingLow = false;
      }
      if(isSwingHigh && highCount < 30)
      {
         swingHighs[highCount]     = m15Rates[i].high;
         swingHighTimes[highCount] = m15Rates[i].time;
         highCount++;
      }
      if(isSwingLow && lowCount < 30)
      {
         swingLows[lowCount]     = m15Rates[i].low;
         swingLowTimes[lowCount] = m15Rates[i].time;
         lowCount++;
      }
   }

   double tolPrice = LiqPoolTolPips * PipSize;

   // Find equal highs (BSL) — 2+ swings within tolerance
   for(int i = 0; i < highCount; i++)
   {
      int matches = 1;
      double avgPrice = swingHighs[i];
      for(int j = i+1; j < highCount; j++)
      {
         if(MathAbs(swingHighs[i] - swingHighs[j]) <= tolPrice)
         {
            matches++;
            avgPrice += swingHighs[j];
         }
      }
      if(matches >= 2 && LiqPoolCount < MaxLiqPools)
      {
         LiqPools[LiqPoolCount].price    = avgPrice / matches;
         LiqPools[LiqPoolCount].isBSL   = true;
         LiqPools[LiqPoolCount].consumed = false;
         LiqPools[LiqPoolCount].created  = swingHighTimes[i];
         LiqPoolCount++;
         i += matches - 1; // Skip matched
      }
   }

   // Find equal lows (SSL)
   for(int i = 0; i < lowCount; i++)
   {
      int matches = 1;
      double avgPrice = swingLows[i];
      for(int j = i+1; j < lowCount; j++)
      {
         if(MathAbs(swingLows[i] - swingLows[j]) <= tolPrice)
         {
            matches++;
            avgPrice += swingLows[j];
         }
      }
      if(matches >= 2 && LiqPoolCount < MaxLiqPools)
      {
         LiqPools[LiqPoolCount].price    = avgPrice / matches;
         LiqPools[LiqPoolCount].isBSL   = false;
         LiqPools[LiqPoolCount].consumed = false;
         LiqPools[LiqPoolCount].created  = swingLowTimes[i];
         LiqPoolCount++;
         i += matches - 1;
      }
   }

   if(VerboseLogging)
      Print("M15 Liquidity Pools: ", LiqPoolCount, " pools found.");
}

//+------------------------------------------------------------------+
//| M5 FAIR VALUE GAP DETECTION                                      |
//+------------------------------------------------------------------+
void ScanM5FVGs()
{
   FVGCount = 0;

   MqlRates m5Rates[];
   ArraySetAsSeries(m5Rates, true);
   int copied = CopyRates(Symbol(), PERIOD_M5, 0, 100, m5Rates);
   if(copied < 3) return;

   // Scan for FVGs: 3-candle pattern
   for(int i = 1; i < copied - 1; i++)
   {
      double c1_high = m5Rates[i+1].high;
      double c1_low  = m5Rates[i+1].low;
      double c3_high = m5Rates[i-1].high;
      double c3_low  = m5Rates[i-1].low;

      // Bullish FVG: c3.low > c1.high (gap between candle 1 high and candle 3 low)
      if(c3_low > c1_high && FVGCount < MaxFVGStore)
      {
         FVGZones[FVGCount].high      = c3_low;
         FVGZones[FVGCount].low       = c1_high;
         FVGZones[FVGCount].mid       = (c3_low + c1_high) / 2.0;
         FVGZones[FVGCount].isBullish = true;
         FVGZones[FVGCount].mitigated = false;
         FVGZones[FVGCount].created   = m5Rates[i].time;
         FVGCount++;
      }
      // Bearish FVG: c3.high < c1.low
      else if(c3_high < c1_low && FVGCount < MaxFVGStore)
      {
         FVGZones[FVGCount].high      = c1_low;
         FVGZones[FVGCount].low       = c3_high;
         FVGZones[FVGCount].mid       = (c1_low + c3_high) / 2.0;
         FVGZones[FVGCount].isBullish = false;
         FVGZones[FVGCount].mitigated = false;
         FVGZones[FVGCount].created   = m5Rates[i].time;
         FVGCount++;
      }
   }

   // Mark mitigated FVGs
   double currentPrice = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   for(int i = 0; i < FVGCount; i++)
   {
      if(FVGZones[i].isBullish && currentPrice < FVGZones[i].low)
         FVGZones[i].mitigated = true;
      if(!FVGZones[i].isBullish && currentPrice > FVGZones[i].high)
         FVGZones[i].mitigated = true;
   }
}

//+------------------------------------------------------------------+
//| ATR CALCULATION                                                   |
//+------------------------------------------------------------------+
void CalcATR()
{
   int atrHandle = iATR(Symbol(), PERIOD_M5, ATRPeriod);
   if(atrHandle == INVALID_HANDLE) return;

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(atrHandle, 0, 0, 6, atrBuf) < 6)
   {
      IndicatorRelease(atrHandle);
      return;
   }

   CurrentATR_M5 = atrBuf[1]; // Last closed bar ATR

   // 5-bar average
   double sum = 0;
   for(int i = 1; i <= 5; i++) sum += atrBuf[i];
   ATRAverage5 = sum / 5.0;

   IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| LIQUIDITY SWEEP DETECTION                                        |
//+------------------------------------------------------------------+
void DetectLiquiditySweep()
{
   if(LiqPoolCount == 0) return;

   MqlRates m1Rates[];
   ArraySetAsSeries(m1Rates, true);
   if(CopyRates(Symbol(), PERIOD_M1, 0, 3, m1Rates) < 2) return;

   double lastHigh  = m1Rates[1].high;
   double lastLow   = m1Rates[1].low;
   double lastClose = m1Rates[1].close;
   double lastOpen  = m1Rates[1].open;

   double sweepMinDist = SweepMinPips * PipSize;
   double sweepMaxDist = SweepMaxPips * PipSize;

   // Check for LONG setup: sweep below SSL (Sell-Side Liquidity)
   if(CurrentBOS == BOS_BULL)
   {
      for(int i = 0; i < LiqPoolCount; i++)
      {
         if(LiqPools[i].isBSL || LiqPools[i].consumed) continue;

         double sslPrice  = LiqPools[i].price;
         double wickBelow = sslPrice - lastLow;

         // Wick spiked below SSL by 2–15 pips and body closed above SSL
         if(wickBelow >= sweepMinDist && wickBelow <= sweepMaxDist
            && lastClose > sslPrice && lastOpen > sslPrice)
         {
            SweepLongConfirmed = true;
            SweepWickExtreme   = lastLow;
            SweepTime          = m1Rates[1].time;
            SweepCandleCount   = 0;
            // Initialize post-sweep swing reference (we need to track M1 swing high)
            PostSweepSwingRef  = lastHigh; // Initial reference
            Print("ILPS: SSL SWEEP DETECTED at ", sslPrice,
                  " | Wick low: ", lastLow);
            if(EnableAlerts) Alert("ILPS: SSL Sweep detected! Pool: ", sslPrice);
            break;
         }
      }
   }

   // Check for SHORT setup: sweep above BSL (Buy-Side Liquidity)
   if(CurrentBOS == BOS_BEAR)
   {
      for(int i = 0; i < LiqPoolCount; i++)
      {
         if(!LiqPools[i].isBSL || LiqPools[i].consumed) continue;

         double bslPrice  = LiqPools[i].price;
         double wickAbove = lastHigh - bslPrice;

         if(wickAbove >= sweepMinDist && wickAbove <= sweepMaxDist
            && lastClose < bslPrice && lastOpen < bslPrice)
         {
            SweepShortConfirmed = true;
            SweepWickExtreme    = lastHigh;
            SweepTime           = m1Rates[1].time;
            SweepCandleCount    = 0;
            PostSweepSwingRef   = lastLow; // Initial reference
            Print("ILPS: BSL SWEEP DETECTED at ", bslPrice,
                  " | Wick high: ", lastHigh);
            if(EnableAlerts) Alert("ILPS: BSL Sweep detected! Pool: ", bslPrice);
            break;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| UPDATE POST-SWEEP SWING REFERENCE (called on each M1 bar)        |
//+------------------------------------------------------------------+
void UpdatePostSweepSwing()
{
   MqlRates m1Rates[];
   ArraySetAsSeries(m1Rates, true);
   if(CopyRates(Symbol(), PERIOD_M1, 0, 4, m1Rates) < 3) return;

   if(SweepLongConfirmed)
   {
      // Track the highest high since sweep for CHoCH reference
      // The CHoCH trigger is when price breaks above a post-sweep swing high
      if(SweepCandleCount == 1)
         PostSweepSwingRef = m1Rates[1].high;
      else
         PostSweepSwingRef = MathMax(PostSweepSwingRef, m1Rates[1].high);
   }
   if(SweepShortConfirmed)
   {
      if(SweepCandleCount == 1)
         PostSweepSwingRef = m1Rates[1].low;
      else
         PostSweepSwingRef = MathMin(PostSweepSwingRef, m1Rates[1].low);
   }
}

//+------------------------------------------------------------------+
//| CHoCH DETECTION                                                  |
//+------------------------------------------------------------------+
void DetectCHoCH()
{
   if(!SweepLongConfirmed && !SweepShortConfirmed) return;

   MqlRates m1Rates[];
   ArraySetAsSeries(m1Rates, true);
   if(CopyRates(Symbol(), PERIOD_M1, 0, 3, m1Rates) < 2) return;

   double currentClose = m1Rates[0].close; // Current (forming) bar
   double lastClose    = m1Rates[1].close; // Last closed bar

   // CHoCH Long: price breaks above the post-sweep swing high
   if(SweepLongConfirmed && !CHoCHLong)
   {
      if(lastClose > PostSweepSwingRef + (1.0 * PipSize))
      {
         CHoCHLong = true;
         Print("ILPS: CHoCH LONG confirmed! Break above: ", PostSweepSwingRef);
         if(EnableAlerts) Alert("ILPS: CHoCH LONG confirmed!");
      }
   }

   // CHoCH Short: price breaks below the post-sweep swing low
   if(SweepShortConfirmed && !CHoCHShort)
   {
      if(lastClose < PostSweepSwingRef - (1.0 * PipSize))
      {
         CHoCHShort = true;
         Print("ILPS: CHoCH SHORT confirmed! Break below: ", PostSweepSwingRef);
         if(EnableAlerts) Alert("ILPS: CHoCH SHORT confirmed!");
      }
   }
}

//+------------------------------------------------------------------+
//| MOMENTUM DELTA FILTER                                            |
//+------------------------------------------------------------------+
bool CheckMomentumDelta(bool forLong)
{
   MqlRates m1Rates[];
   ArraySetAsSeries(m1Rates, true);
   if(CopyRates(Symbol(), PERIOD_M1, 0, 5, m1Rates) < 4) return false;

   int aligned = 0;
   for(int i = 1; i <= 3; i++)
   {
      if(forLong  && m1Rates[i].close > m1Rates[i].open) aligned++;
      if(!forLong && m1Rates[i].close < m1Rates[i].open) aligned++;
   }
   return (aligned >= 2);
}

//+------------------------------------------------------------------+
//| FIND ALIGNED FVG                                                 |
//+------------------------------------------------------------------+
int FindAlignedFVG(bool forLong, double referencePrice)
{
   double maxDist = FVGPoolMaxDist * PipSize;
   int bestIdx    = -1;
   double bestDist = DBL_MAX;

   for(int i = 0; i < FVGCount; i++)
   {
      if(FVGZones[i].mitigated) continue;
      if(FVGZones[i].isBullish != forLong) continue;

      double dist;
      if(forLong)
         dist = MathAbs(FVGZones[i].mid - referencePrice);
      else
         dist = MathAbs(FVGZones[i].mid - referencePrice);

      if(dist <= maxDist && dist < bestDist)
      {
         bestDist = dist;
         bestIdx  = i;
      }
   }
   return bestIdx;
}

//+------------------------------------------------------------------+
//| FULL CONFLUENCE EVALUATION & ENTRY                               |
//+------------------------------------------------------------------+
void EvaluateAndEnter()
{
   if(HasOpenPosition()) return;

   bool forLong = CHoCHLong;

   // Check session trade count
   bool inLondon = IsInLondonSession();
   bool inNY     = IsInNYSession();
   if(inLondon && LondonTradesToday >= MaxLondonTrades) return;
   if(inNY     && NYTradesToday     >= MaxNYTrades)     return;

   // RULE T-6: ATR gate (re-check)
   bool activeVol = (CurrentATR_M5 >= MinATRPips * PipSize);
   bool marginalVol = (!activeVol && CurrentATR_M5 >= MarginalATRPips * PipSize);

   // RULE T-9: Find aligned FVG
   double sweepRef = forLong ? SweepWickExtreme : SweepWickExtreme;
   int fvgIdx = FindAlignedFVG(forLong, sweepRef);

   // RULE T-11: Momentum delta
   bool momentumOK = CheckMomentumDelta(forLong);

   // Count pillars
   int pillars = 0;
   if(CurrentBOS != BOS_NONE)                                    pillars++; // Pillar 1
   if(LiqPoolCount > 0)                                          pillars++; // Pillar 2
   if(fvgIdx >= 0)                                               pillars++; // Pillar 3
   if(SweepLongConfirmed || SweepShortConfirmed)                 pillars++; // Pillar 4
   if(CHoCHLong || CHoCHShort)                                   pillars++; // Pillar 5

   bool isAPlusSetup = (pillars == 5 && momentumOK && activeVol);
   bool isValidSetup = (pillars >= 4 && momentumOK);

   if(!isValidSetup)
   {
      if(VerboseLogging)
         Print("ILPS: Insufficient confluence. Pillars: ", pillars,
               " Momentum: ", momentumOK);
      ResetSweepState();
      return;
   }

   // Marginal vol: only A+ setups
   if(marginalVol && !isAPlusSetup)
   {
      ResetSweepState();
      return;
   }

   // SL calculation
   double slPrice, entryPrice;
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double bufferPips = SweepWickBuffer * PipSize;

   if(forLong)
   {
      entryPrice = ask;
      slPrice    = SweepWickExtreme - bufferPips;
   }
   else
   {
      entryPrice = bid;
      slPrice    = SweepWickExtreme + bufferPips;
   }

   double slPips = MathAbs(entryPrice - slPrice) / PipSize;

   // SL envelope check
   if(slPips < MinSLPips || slPips > MaxSLPips)
   {
      Print("ILPS: SL pips out of envelope: ", slPips);
      ResetSweepState();
      return;
   }

   // Risk calculation
   double riskPct    = isAPlusSetup ? APlusRiskPercent : BaseRiskPercent;
   // Reduce lot if marginal conditions or loss streak
   if(ConsecutiveLosses >= PauseTrades2) riskPct *= 0.75;
   if(RecoveryMode) riskPct = MathMin(riskPct, BaseRiskPercent * 0.5);

   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount  = equity * riskPct / 100.0;
   double tickValue   = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tickSize    = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   double pipValue    = (PipSize / tickSize) * tickValue;
   double lotSize     = riskAmount / (slPips * pipValue);
   double minLot      = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxLot      = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double lotStep     = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(lotSize, minLot);
   lotSize = MathMin(lotSize, maxLot);

   // TP levels
   double slDist = MathAbs(entryPrice - slPrice);
   double tp1, tp2, tp3;

   // Find opposing liquidity pool for TP3
   double oppLiqPool = FindOpposingLiquidityPool(forLong, entryPrice);

   if(forLong)
   {
      tp1 = entryPrice + slDist * TP1_RR;
      tp2 = entryPrice + slDist * TP2_RR;
      tp3 = (oppLiqPool > 0) ? MathMin(oppLiqPool, entryPrice + slDist * TP3_RR)
                              : entryPrice + slDist * TP3_RR;
   }
   else
   {
      tp1 = entryPrice - slDist * TP1_RR;
      tp2 = entryPrice - slDist * TP2_RR;
      tp3 = (oppLiqPool > 0) ? MathMax(oppLiqPool, entryPrice - slDist * TP3_RR)
                              : entryPrice - slDist * TP3_RR;
   }

   // --- EXECUTE TRADE ---
   // Split into 3 sub-positions for tiered TP management
   double lot1 = MathFloor(lotSize * (TP1_ClosePct/100.0) / lotStep) * lotStep;
   double lot2 = MathFloor(lotSize * (TP2_ClosePct/100.0) / lotStep) * lotStep;
   double lot3 = MathMax(lotSize - lot1 - lot2, minLot);

   lot1 = MathMax(lot1, minLot);
   lot2 = MathMax(lot2, minLot);

   bool sent = false;

   if(forLong)
   {
      // TP1 position
      sent = trade.Buy(lot1, Symbol(), ask, slPrice, tp1,
                       EAMagicComment + "_TP1");
      if(sent) trade.Buy(lot2, Symbol(), ask, slPrice, tp2,
                         EAMagicComment + "_TP2");
      if(sent) trade.Buy(lot3, Symbol(), ask, slPrice, tp3,
                         EAMagicComment + "_TP3");
   }
   else
   {
      sent = trade.Sell(lot1, Symbol(), bid, slPrice, tp1,
                        EAMagicComment + "_TP1");
      if(sent) trade.Sell(lot2, Symbol(), bid, slPrice, tp2,
                          EAMagicComment + "_TP2");
      if(sent) trade.Sell(lot3, Symbol(), bid, slPrice, tp3,
                          EAMagicComment + "_TP3");
   }

   if(sent)
   {
      EntryPrice        = forLong ? ask : bid;
      InitialSLPrice    = slPrice;
      CurrentSL         = slPrice;
      SLPipsDistance    = slPips;
      TradeOpenTime     = TimeCurrent();
      LastTradeDirection = forLong ? 1 : -1;
      TP1Hit            = false;
      TP2Hit            = false;
      TrailingActive    = false;
      TradesToday++;
      if(inLondon) LondonTradesToday++;
      if(inNY)     NYTradesToday++;

      Print("ILPS: TRADE EXECUTED | Dir: ", forLong ? "LONG" : "SHORT",
            " | Entry: ", EntryPrice,
            " | SL: ", slPrice, " (", slPips, " pips)",
            " | TP1: ", tp1, " TP2: ", tp2, " TP3: ", tp3,
            " | Lots: ", lot1+lot2+lot3,
            " | Pillars: ", pillars,
            " | A+: ", isAPlusSetup,
            " | ATR: ", CurrentATR_M5/PipSize, " pips");

      if(EnableAlerts)
         Alert("ILPS TRADE: ", forLong ? "BUY" : "SELL",
               " | Entry: ", EntryPrice, " | SL: ", slPrice);
   }
   else
   {
      Print("ILPS: Order failed. Error: ", GetLastError());
   }

   // Mark used liquidity pool as consumed
   MarkPoolConsumed(forLong);
   // Mark FVG as mitigated
   if(fvgIdx >= 0) FVGZones[fvgIdx].mitigated = true;
   // Reset sweep/CHoCH state
   ResetSweepState();
}

//+------------------------------------------------------------------+
//| FIND OPPOSING LIQUIDITY POOL FOR TP3                             |
//+------------------------------------------------------------------+
double FindOpposingLiquidityPool(bool forLong, double entryPrice)
{
   double best = 0;
   double bestDist = DBL_MAX;

   for(int i = 0; i < LiqPoolCount; i++)
   {
      if(LiqPools[i].consumed) continue;
      if(forLong  && !LiqPools[i].isBSL) continue; // Want BSL above
      if(!forLong && LiqPools[i].isBSL)  continue; // Want SSL below

      double dist = MathAbs(LiqPools[i].price - entryPrice);
      if(dist < bestDist && dist > (MinSLPips * PipSize))
      {
         bestDist = dist;
         best     = LiqPools[i].price;
      }
   }
   return best;
}

//+------------------------------------------------------------------+
//| MARK LIQUIDITY POOL AS CONSUMED                                  |
//+------------------------------------------------------------------+
void MarkPoolConsumed(bool longTrade)
{
   for(int i = 0; i < LiqPoolCount; i++)
   {
      if(LiqPools[i].consumed) continue;
      // For long: mark the SSL that was swept
      if(longTrade && !LiqPools[i].isBSL)
      {
         if(MathAbs(LiqPools[i].price - SweepWickExtreme) < 20 * PipSize)
         {
            LiqPools[i].consumed = true;
            break;
         }
      }
      // For short: mark the BSL that was swept
      if(!longTrade && LiqPools[i].isBSL)
      {
         if(MathAbs(LiqPools[i].price - SweepWickExtreme) < 20 * PipSize)
         {
            LiqPools[i].consumed = true;
            break;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| OPEN TRADE MANAGEMENT                                            |
//+------------------------------------------------------------------+
void ManageOpenTrade()
{
   if(!HasOpenPosition()) return;

   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double currentPrice = (LastTradeDirection == 1) ? bid : ask;

   // TP1 Check: Move SL to break-even
   if(!TP1Hit)
   {
      double tp1Dist = SLPipsDistance * TP1_RR * PipSize;
      bool tp1Reached = (LastTradeDirection == 1)
                        ? (bid >= EntryPrice + tp1Dist)
                        : (ask <= EntryPrice - tp1Dist);
      if(tp1Reached)
      {
         TP1Hit = true;
         // Move SL to breakeven + 1 pip
         double newSL = (LastTradeDirection == 1)
                        ? EntryPrice + PipSize
                        : EntryPrice - PipSize;
         ModifyAllSLs(newSL);
         CurrentSL = newSL;
         Print("ILPS: TP1 hit. SL moved to break-even: ", newSL);
      }
   }

   // TP2 Check: Activate trailing
   if(TP1Hit && !TP2Hit)
   {
      double tp2Dist = SLPipsDistance * TP2_RR * PipSize;
      bool tp2Reached = (LastTradeDirection == 1)
                        ? (bid >= EntryPrice + tp2Dist)
                        : (ask <= EntryPrice - tp2Dist);
      if(tp2Reached)
      {
         TP2Hit       = true;
         TrailingActive = true;
         Print("ILPS: TP2 hit. Trailing stop activated.");
      }
   }

   // Trailing stop management
   if(TrailingActive)
   {
      double trailDist = TrailStopPips * PipSize;
      double newSL;
      if(LastTradeDirection == 1)
      {
         newSL = bid - trailDist;
         if(newSL > CurrentSL)
         {
            ModifyAllSLs(newSL);
            CurrentSL = newSL;
         }
      }
      else
      {
         newSL = ask + trailDist;
         if(newSL < CurrentSL)
         {
            ModifyAllSLs(newSL);
            CurrentSL = newSL;
         }
      }
   }

   // TIME EXIT: close if open too long without TP1
   if(!TP1Hit)
   {
      int minutesOpen = (int)((TimeCurrent() - TradeOpenTime) / 60);
      if(minutesOpen >= MaxTradeMinutes)
      {
         CloseAllPositions("TIME_EXIT");
         Print("ILPS: Time exit triggered after ", minutesOpen, " minutes.");
         return;
      }
   }

   // INVALIDATION: Spread crisis
   double spreadPips = GetSpreadPips();
   if(spreadPips >= CrisisSpreadPips)
   {
      CloseAllPositions("CRISIS_SPREAD");
      return;
   }

   // INVALIDATION: Check for counter-BOS on M5
   if(IsCounterBOSFormed())
   {
      CloseAllPositions("COUNTER_BOS");
      Print("ILPS: Counter-BOS invalidation. Exiting.");
      return;
   }

   // INVALIDATION: Price re-entered swept pool body
   if(SweepPoolReentered())
   {
      CloseAllPositions("POOL_REENTRY");
      Print("ILPS: Swept pool re-entered. Exiting.");
      return;
   }
}

//+------------------------------------------------------------------+
//| MODIFY ALL OPEN POSITION STOP LOSSES                             |
//+------------------------------------------------------------------+
void ModifyAllSLs(double newSL)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == Symbol() && posInfo.Magic() == MAGIC_NUMBER)
         {
            double normalizedSL = NormalizeDouble(newSL, Digits());
            if(MathAbs(posInfo.StopLoss() - normalizedSL) > PipSize * 0.5)
               trade.PositionModify(posInfo.Ticket(), normalizedSL, posInfo.TakeProfit());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| CLOSE ALL POSITIONS                                              |
//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
{
   double totalPL = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == Symbol() && posInfo.Magic() == MAGIC_NUMBER)
         {
            totalPL += posInfo.Profit();
            trade.PositionClose(posInfo.Ticket(), 50); // 5 pip slippage max
         }
      }
   }

   // Update streak tracking
   if(totalPL < 0)
   {
      ConsecutiveLosses++;
      ConsecutiveWins = 0;
      DailyLossUsed += MathAbs(totalPL);
      Print("ILPS: Loss recorded. Consecutive: ", ConsecutiveLosses,
            " | Daily loss used: $", DailyLossUsed);
      CheckLossStreak();
   }
   else if(totalPL > 0)
   {
      ConsecutiveWins++;
      if(ConsecutiveWins >= 2 && ConsecutiveLosses > 0)
         ConsecutiveLosses = 0; // Reset streak after 2 consecutive wins
      Print("ILPS: Win recorded. Consecutive wins: ", ConsecutiveWins);
   }

   Print("ILPS: All positions closed. Reason: ", reason, " | P&L: $", totalPL);
}

//+------------------------------------------------------------------+
//| CHECK LOSS STREAK RULES                                          |
//+------------------------------------------------------------------+
bool CheckLossStreak()
{
   if(ConsecutiveLosses >= PauseTrades5)
   {
      PauseUntil     = TimeCurrent() + 86400; // 24 hours
      TradingHalted  = true;
      Print("ILPS: 5+ consecutive losses. EA paused 24 hours.");
      if(EnableAlerts) Alert("ILPS: 5 consecutive losses! EA paused 24 hours.");
      return false;
   }
   if(ConsecutiveLosses >= PauseTrades4)
   {
      PauseUntil     = GetEndOfDay();
      TradingHalted  = true;
      Print("ILPS: 4 consecutive losses. Halted for day.");
      return false;
   }
   if(ConsecutiveLosses >= PauseTrades3)
   {
      // Pause 1 full session
      PauseUntil    = TimeCurrent() + 4 * 3600; // ~4 hours
      TradingHalted = true;
      Print("ILPS: 3 consecutive losses. Halted for 1 session.");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| COUNTER BOS CHECK FOR INVALIDATION                              |
//+------------------------------------------------------------------+
bool IsCounterBOSFormed()
{
   MqlRates m5Rates[];
   ArraySetAsSeries(m5Rates, true);
   if(CopyRates(Symbol(), PERIOD_M5, 0, 20, m5Rates) < 10) return false;

   // Look for a swing structure break against the trade direction
   if(LastTradeDirection == 1) // Long trade — check for bearish BOS
   {
      for(int i = SwingLookback; i < 15; i++)
      {
         bool isSwingLow = true;
         for(int j = 1; j <= SwingLookback; j++)
         {
            if(i-j < 0 || i+j >= 20) { isSwingLow = false; break; }
            if(m5Rates[i].low >= m5Rates[i-j].low || m5Rates[i].low >= m5Rates[i+j].low)
               isSwingLow = false;
         }
         if(isSwingLow && m5Rates[0].close < m5Rates[i].low)
            return true; // Bear BOS — counter to long
      }
   }
   else if(LastTradeDirection == -1) // Short trade — check for bullish BOS
   {
      for(int i = SwingLookback; i < 15; i++)
      {
         bool isSwingHigh = true;
         for(int j = 1; j <= SwingLookback; j++)
         {
            if(i-j < 0 || i+j >= 20) { isSwingHigh = false; break; }
            if(m5Rates[i].high <= m5Rates[i-j].high || m5Rates[i].high <= m5Rates[i+j].high)
               isSwingHigh = false;
         }
         if(isSwingHigh && m5Rates[0].close > m5Rates[i].high)
            return true; // Bull BOS — counter to short
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| CHECK IF PRICE RE-ENTERED SWEPT POOL                            |
//+------------------------------------------------------------------+
bool SweepPoolReentered()
{
   if(SweepWickExtreme == 0) return false;
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);

   if(LastTradeDirection == 1)  // Long: price going back below wick low
      return (bid < SweepWickExtreme);
   if(LastTradeDirection == -1) // Short: price going back above wick high
      return (ask > SweepWickExtreme);
   return false;
}

//+------------------------------------------------------------------+
//| SESSION CHECKS                                                   |
//+------------------------------------------------------------------+
bool IsInTradingSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int h = dt.hour;
   int m = dt.min;
   int timeInMins = h * 60 + m;

   int londonStart = LondonOpenHour * 60;
   int londonEnd   = LondonCloseHour * 60 + LondonCloseMin;
   int nyStart     = NYOpenHour * 60;
   int nyEnd       = NYCloseHour * 60 + NYCloseMin;

   bool inLondon = (timeInMins >= londonStart && timeInMins <= londonEnd);
   bool inNY     = (timeInMins >= nyStart     && timeInMins <= nyEnd);
   return (inLondon || inNY);
}

bool IsInLondonSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int timeInMins = dt.hour * 60 + dt.min;
   return (timeInMins >= LondonOpenHour * 60 &&
           timeInMins <= LondonCloseHour * 60 + LondonCloseMin);
}

bool IsInNYSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int timeInMins = dt.hour * 60 + dt.min;
   return (timeInMins >= NYOpenHour * 60 &&
           timeInMins <= NYCloseHour * 60 + NYCloseMin);
}

//+------------------------------------------------------------------+
//| NEWS BLACKOUT CHECK                                              |
//+------------------------------------------------------------------+
void ParseNewsEvents()
{
   NewsEventCount = 0;
   string events[5];
   events[0] = NewsEvent1;
   events[1] = NewsEvent2;
   events[2] = NewsEvent3;
   events[3] = NewsEvent4;
   events[4] = NewsEvent5;

   for(int i = 0; i < 5; i++)
   {
      if(StringLen(events[i]) < 8) continue;
      // Format: MMDD-HH:MM
      string datePart = StringSubstr(events[i], 0, 4); // MMDD
      string timePart = StringSubstr(events[i], 5, 5); // HH:MM

      int month  = (int)StringToInteger(StringSubstr(datePart, 0, 2));
      int day    = (int)StringToInteger(StringSubstr(datePart, 2, 2));
      int hour   = (int)StringToInteger(StringSubstr(timePart, 0, 2));
      int minute = (int)StringToInteger(StringSubstr(timePart, 3, 2));

      MqlDateTime dt;
      TimeToStruct(TimeGMT(), dt);
      dt.mon  = month;
      dt.day  = day;
      dt.hour = hour;
      dt.min  = minute;
      dt.sec  = 0;

      NewsEvents[NewsEventCount] = StructToTime(dt);
      NewsEventCount++;
   }
}

bool IsNewsBlackout()
{
   datetime now = TimeGMT();
   int bufferSec = NewsBufferMinutes * 60;

   for(int i = 0; i < NewsEventCount; i++)
   {
      if(MathAbs((long)(now - NewsEvents[i])) <= bufferSec)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| SPREAD HELPER                                                    |
//+------------------------------------------------------------------+
double GetSpreadPips()
{
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   return (ask - bid) / PipSize;
}

//+------------------------------------------------------------------+
//| HAS OPEN POSITION                                                |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == Symbol() && posInfo.Magic() == MAGIC_NUMBER)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| RESET SWEEP AND CHoCH STATE                                      |
//+------------------------------------------------------------------+
void ResetSweepState()
{
   SweepLongConfirmed  = false;
   SweepShortConfirmed = false;
   SweepWickExtreme    = 0.0;
   SweepTime           = 0;
   SweepCandleCount    = 0;
   CHoCHLong           = false;
   CHoCHShort          = false;
   PostSweepSwingRef   = 0.0;
}

//+------------------------------------------------------------------+
//| DAILY RESET                                                      |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   datetime dayStart = StringToTime(StringFormat("%04d.%02d.%02d 00:00",
                       dt.year, dt.mon, dt.day));

   if(dayStart != LastDayChecked)
   {
      LastDayChecked    = dayStart;
      TradesToday       = 0;
      LondonTradesToday = 0;
      NYTradesToday     = 0;
      DailyLossUsed     = 0.0;

      // Check recovery mode
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      PeakEquity    = MathMax(PeakEquity, equity);
      double drawdown = (PeakEquity - equity) / PeakEquity * 100.0;
      RecoveryMode  = (drawdown >= RecoveryDrawdownPct);
      if(RecoveryMode)
         Print("ILPS: Recovery mode ACTIVE. Drawdown: ", drawdown, "%");

      // Reset pauses (day-level pauses clear at new day)
      if(TradingHalted && PauseUntil <= TimeCurrent())
         TradingHalted = false;

      // Clear session liquidity pools and FVGs for new day
      ScanM15LiquidityPools();
      ScanM5FVGs();
      ResetSweepState();

      Print("ILPS: Daily reset. New trading day started.");
   }
}

//+------------------------------------------------------------------+
//| WEEKLY RESET                                                     |
//+------------------------------------------------------------------+
void CheckWeeklyReset()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   // Week starts Monday
   if(dt.day_of_week == 1) // Monday
   {
      datetime weekStart = StringToTime(StringFormat("%04d.%02d.%02d 00:00",
                           dt.year, dt.mon, dt.day));
      if(weekStart != LastWeekChecked)
      {
         LastWeekChecked = weekStart;
         WeeklyLossUsed  = 0.0;
         Print("ILPS: Weekly reset.");
      }
   }
}

//+------------------------------------------------------------------+
//| GET END OF DAY TIMESTAMP                                         |
//+------------------------------------------------------------------+
datetime GetEndOfDay()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   dt.hour = 23;
   dt.min  = 59;
   dt.sec  = 59;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| END OF SESSION CLEANUP (called at 16:00 GMT)                    |
//+------------------------------------------------------------------+
void CheckEndOfSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   if(dt.hour == 16 && dt.min == 0)
   {
      CloseAllPositions("SESSION_END");
      ResetSweepState();
      Print("ILPS: Session ended. All positions closed.");
   }
}

//+------------------------------------------------------------------+
//| DASHBOARD DISPLAY                                                |
//+------------------------------------------------------------------+
void DrawDashboard()
{
   string labels[] = {
      "title", "bos", "session", "spread", "atr",
      "pools", "fvgs", "sweep", "choch", "trades",
      "daily_loss", "streak", "mode", "pillar_count"
   };

   int y = 20;
   for(int i = 0; i < ArraySize(labels); i++)
   {
      string name = LabelPrefix + labels[i];
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
      ObjectSetString(0,  name, OBJPROP_FONT, "Consolas");
      y += 16;
   }
}

void UpdateDashboard()
{
   if(!ShowDashboard) return;

   double spread = GetSpreadPips();
   string session = IsInLondonSession() ? "LONDON" :
                    IsInNYSession()      ? "NY OVERLAP" : "OUT OF SESSION";
   string bosStr  = (CurrentBOS == BOS_BULL) ? "BULLISH ▲" :
                    (CurrentBOS == BOS_BEAR) ? "BEARISH ▼" : "NONE";

   string sweepStr = SweepLongConfirmed ? "LONG SWEEP ✓" :
                     SweepShortConfirmed ? "SHORT SWEEP ✓" : "---";
   string chochStr = CHoCHLong ? "CHoCH LONG ✓" :
                     CHoCHShort ? "CHoCH SHORT ✓" : "---";
   string modeStr  = RecoveryMode ? "⚠ RECOVERY" :
                     TradingHalted ? "⛔ HALTED" : "✓ ACTIVE";
   string atrStr   = StringFormat("%.1f pips", CurrentATR_M5 / PipSize);

   SetLabel("title",       "══ ILPS XAUUSD HFT EA ══", clrGold);
   SetLabel("bos",         "BOS:     " + bosStr,
            CurrentBOS==BOS_BULL ? BullColor : BearColor);
   SetLabel("session",     "SESSION: " + session, clrWhite);
   SetLabel("spread",      StringFormat("SPREAD:  %.1f pips", spread),
            spread > MaxSpreadPips ? clrRed : clrLimeGreen);
   SetLabel("atr",         "ATR:     " + atrStr,
            CurrentATR_M5 >= MinATRPips*PipSize ? clrLimeGreen : clrOrange);
   SetLabel("pools",       StringFormat("LIQ POOLS: %d", LiqPoolCount), clrWhite);
   SetLabel("fvgs",        StringFormat("FVGs:      %d", FVGCount), clrWhite);
   SetLabel("sweep",       "SWEEP:   " + sweepStr,
            (SweepLongConfirmed||SweepShortConfirmed) ? clrYellow : clrGray);
   SetLabel("choch",       "CHoCH:   " + chochStr,
            (CHoCHLong||CHoCHShort) ? clrLimeGreen : clrGray);
   SetLabel("trades",      StringFormat("TRADES:  %d / %d", TradesToday, MaxTradesPerDay),
            TradesToday >= MaxTradesPerDay ? clrRed : clrWhite);
   SetLabel("daily_loss",  StringFormat("DAILY P&L: -$%.2f", DailyLossUsed), clrWhite);
   SetLabel("streak",      StringFormat("LOSSES:  %d streak", ConsecutiveLosses),
            ConsecutiveLosses >= 2 ? clrOrange : clrWhite);
   SetLabel("mode",        "STATUS:  " + modeStr,
            RecoveryMode||TradingHalted ? clrOrange : clrLimeGreen);
   SetLabel("pillar_count","PILLARS: Liq=" + IntegerToString(LiqPoolCount) +
            " FVG=" + IntegerToString(FVGCount), clrSilver);

   ChartRedraw(0);
}

void SetLabel(string key, string text, color clr)
{
   string name = LabelPrefix + key;
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

void RemoveDashboard()
{
   ObjectsDeleteAll(0, LabelPrefix);
}

//+------------------------------------------------------------------+
//| OnTradeTransaction - track closed trades                         |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   // Detect position close and update equity peak
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      PeakEquity    = MathMax(PeakEquity, equity);
   }
}

//+------------------------------------------------------------------+
//| END OF FILE                                                      |
//+------------------------------------------------------------------+

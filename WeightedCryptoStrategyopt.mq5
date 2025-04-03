datetime lastCalcTime = 0;

// 1) Factor weights
input double InpW_Momentum = 1.0; 
input double InpW_Volatility = 1.0;
input double InpW_MACD = 1.0;      
input double InpW_Donchian = 1.0; 

// 2) Stop-loss percent for both longs & shorts, default 0.05, but we can optimize >0.05
input double InpStopLossPct = 0.05; 

// List of coin symbols
string Symbols[] = {
   "ADAUSD","AVXUSD","BCHUSD","BNBUSD","BTCUSD",
   "DOGUSD","DOTUSD","DSHUSD","EOSUSD","ETHUSD",
   "GLMUSD","KSMUSD","LNKUSD","LTCUSD","MTCUSD",
   "SOLUSD","UNIUSD","XLMUSD","XRPUSD","XTZUSD"
};

// Cluster assignments for each coin in the same order as Symbols
int Clusters[20] = {
   0,0,0,1,1,
   0,0,2,2,1,
   1,2,2,0,0,
   1,2,2,0,0
};

// Forward declarations
double GetMomentumFactor(string sym);
double GetVolatilityFactor(string sym);
double GetMACDFactor(string sym);
double GetDonchianFactor(string sym);
void   NormalizeZScore(double &arr[]);
double AdjustToVolumeStep(string symbol, double volume);

// Structures
struct CoinScore {
   string symbol;
   double score;
};

struct ActivePosition {
   string symbol;
   double entryPrice; // For long: we expect close>entry triggers stop-loss
   double lotSize;
};

struct ShortPosition {
   string symbol;
   double entryPrice; // For short: if currentPrice>entryPrice*(1+SL) => stop out
   double lotSize;
};

// We track two arrays: one for longs, one for shorts
ActivePosition currentPositions[];
ShortPosition  currentShorts[];

//---------------------------------------------------------//
// Trading Functions
//---------------------------------------------------------//

// open a buy (long) position
void OpenBuyPosition(string symbol, double lotSize)
{
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.symbol       = symbol;
   request.volume       = lotSize;
   request.type         = ORDER_TYPE_BUY;
   request.action       = TRADE_ACTION_DEAL;
   request.deviation    = 10;
   request.magic        = 123456;
   request.type_filling = ORDER_FILLING_IOC;
   request.type_time    = ORDER_TIME_GTC;

   if(!OrderSend(request, result))
      Print("Failed to open buy position on ", symbol, " Error: ", GetLastError());
   else
      Print("Opened buy position on ", symbol, " Volume: ", lotSize);
}

// open a sell (short) position
void OpenShortPosition(string symbol, double lotSize)
{
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.symbol       = symbol;
   request.volume       = lotSize;
   request.type         = ORDER_TYPE_SELL;  // netting mode => short
   request.action       = TRADE_ACTION_DEAL;
   request.deviation    = 10;
   request.magic        = 123456;
   request.type_filling = ORDER_FILLING_IOC;
   request.type_time    = ORDER_TIME_GTC;

   if(!OrderSend(request, result))
      Print("Failed to open SHORT position on ", symbol, " Error: ", GetLastError());
   else
      Print("Opened short position on ", symbol, " Volume: ", lotSize);
}

// close all positions (long or short) for a given symbol
void CloseAllPositions(string symbol)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == symbol)
      {
         ulong ticket   = PositionGetInteger(POSITION_TICKET);
         double volume  = PositionGetDouble(POSITION_VOLUME);
         int    type    = (int)PositionGetInteger(POSITION_TYPE);

         MqlTradeRequest request;
         MqlTradeResult  result;
         ZeroMemory(request);
         ZeroMemory(result);

         request.action    = TRADE_ACTION_DEAL;
         request.position  = ticket;
         request.symbol    = symbol;
         request.volume    = volume;
         request.deviation = 10;
         request.magic     = 123456;
         request.type_filling = ORDER_FILLING_IOC;
         request.type_time    = ORDER_TIME_GTC;

         if(type == POSITION_TYPE_BUY)
            request.type = ORDER_TYPE_SELL; // close a long
         else if(type == POSITION_TYPE_SELL)
            request.type = ORDER_TYPE_BUY;  // close a short
         else
            continue;

         if(!OrderSend(request, result))
            Print("Failed to close position on ", symbol, " Error: ", GetLastError());
         else
            Print("Closed position on ", symbol, " Volume: ", volume);
      }
   }
}

// sort coinScores in descending order by score
void SortCoinScoresDescending(CoinScore &arr[])
{
   int n = ArraySize(arr);
   for(int i = 0; i < n - 1; i++)
   {
      for(int j = i + 1; j < n; j++)
      {
         if(arr[i].score < arr[j].score)
         {
            CoinScore tmp = arr[i];
            arr[i]        = arr[j];
            arr[j]        = tmp;
         }
      }
   }
}

//---------------------------------------------------------//
// OnInit
//---------------------------------------------------------//
int OnInit()
{
   // Make sure each symbol is in Market Watch
   for(int i=0; i < ArraySize(Symbols); i++)
   {
      if(!SymbolSelect(Symbols[i], true))
         Print("Failed to select symbol: ", Symbols[i]);
      else
         Print("Symbol selected: ", Symbols[i]);
   }
   Print("Factor Calculation EA Initialized.");
   return INIT_SUCCEEDED;
}

//---------------------------------------------------------//
// OnTick (Rebalancing)
//---------------------------------------------------------//
void OnTick()
{
   // Only recalc every 8 hours
   if(TimeCurrent() < lastCalcTime + 8*3600) return;
   lastCalcTime = TimeCurrent();

   // 1) Gather factor arrays
   double mom[], vol[], macd[], donch[], score[];
   ArrayResize(mom,   ArraySize(Symbols));
   ArrayResize(vol,   ArraySize(Symbols));
   ArrayResize(macd,  ArraySize(Symbols));
   ArrayResize(donch, ArraySize(Symbols));
   ArrayResize(score, ArraySize(Symbols));

   // Step 1: raw factors
   for(int i=0; i < ArraySize(Symbols); i++)
   {
      string sym = Symbols[i];
      mom[i]   = GetMomentumFactor(sym);
      vol[i]   = GetVolatilityFactor(sym);
      macd[i]  = GetMACDFactor(sym);
      donch[i] = GetDonchianFactor(sym);

      Print("Symbol: ", sym,
            " | MOM: ",   DoubleToString(mom[i],6),
            " | VOL: ",   DoubleToString(vol[i],6),
            " | MACD: ",  DoubleToString(macd[i],6),
            " | Donch: ", DoubleToString(donch[i],6));
   }

   // Step 2: normalize each factor
   NormalizeZScore(mom);
   NormalizeZScore(vol);
   NormalizeZScore(macd);
   NormalizeZScore(donch);

   // Step 3: combined score
   double w_mom=InpW_Momentum, w_vol=InpW_Volatility, w_macd=InpW_MACD, w_donch=InpW_Donchian;
   for(int i=0; i<ArraySize(Symbols); i++)
   {
      score[i] = w_mom*mom[i] + w_vol*vol[i] + w_macd*macd[i] + w_donch*donch[i];
      Print("Symbol: ", Symbols[i], " | Score: ", DoubleToString(score[i],6));
   }

   // Step 4: rank by cluster & print full ranking
   int minCluster = Clusters[0], maxCluster = Clusters[0];
   for(int i=1; i<ArraySize(Clusters); i++)
   {
      if(Clusters[i]<minCluster) minCluster=Clusters[i];
      if(Clusters[i]>maxCluster) maxCluster=Clusters[i];
   }

   // We'll pick top 2 for LONG, bottom 2 for SHORT
   int topR    = 2;
   int bottomR = 2;

   string coinsToLong[];
   string coinsToShort[];

   for(int cl = minCluster; cl <= maxCluster; cl++)
   {
      CoinScore clusterScores[];
      // gather coins in this cluster
      for(int i=0; i<ArraySize(Symbols); i++)
      {
         if(Clusters[i]==cl)
         {
            CoinScore cs;
            cs.symbol = Symbols[i];
            cs.score  = score[i];
            ArrayResize(clusterScores, ArraySize(clusterScores)+1);
            clusterScores[ArraySize(clusterScores)-1]=cs;
         }
      }

      // if there's anything in clusterScores, sort & print
      if(ArraySize(clusterScores)>0)
      {
         SortCoinScoresDescending(clusterScores);
         Print("----- Ranking for Cluster ", cl," -----");
         for(int j=0; j<ArraySize(clusterScores); j++)
         {
            Print("Rank ", j+1, ": ", clusterScores[j].symbol,
                  " with Score: ", DoubleToString(clusterScores[j].score,6));
         }

         // pick topR for LONG
         for(int j=0; j<MathMin(topR,ArraySize(clusterScores)); j++)
         {
            int idx = ArraySize(coinsToLong);
            ArrayResize(coinsToLong, idx+1);
            coinsToLong[idx] = clusterScores[j].symbol;
         }

         // pick bottomR for SHORT
         // e.g. last 2 in that cluster
         for(int j= ArraySize(clusterScores)-1; j>=MathMax(ArraySize(clusterScores)-bottomR, 0); j--)
         {
            int idx = ArraySize(coinsToShort);
            ArrayResize(coinsToShort, idx+1);
            coinsToShort[idx] = clusterScores[j].symbol;
         }
      }
   }

   if(ArraySize(coinsToLong)==0 && ArraySize(coinsToShort)==0)
   {
      Print("No coins selected to trade.");
      return;
   }

   //---------------------------------------------------------
   // Compute how much money to invest PER coin for LONG => 10%
   // how much money to invest PER coin for SHORT => 5%
   //---------------------------------------------------------
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   double fractionLong  = 0.10; // invests 10% in each coin selected for LONG
   double fractionShort = 0.05; // invests 5% in each coin selected for SHORT

   double moneyPerLong  = equity * fractionLong;
   double moneyPerShort = equity * fractionShort;

   Print("Equity=", DoubleToString(equity,2), 
         " => moneyPerLong=", DoubleToString(moneyPerLong,2),
         ", moneyPerShort=",DoubleToString(moneyPerShort,2));

   //---------------------------------------------------------
   // 1) Re-weight existing LONG positions
   //---------------------------------------------------------
   for(int i=ArraySize(currentPositions)-1; i>=0; i--)
   {
      string heldCoin   = currentPositions[i].symbol;

      // do we still want this coin LONG?
      bool stillWanted = false;
      for(int j=0; j<ArraySize(coinsToLong); j++)
      {
         if(heldCoin==coinsToLong[j]) { stillWanted=true; break; }
      }

      if(!stillWanted)
      {
         // close & remove from array
         CloseAllPositions(heldCoin);
         ArrayRemove(currentPositions, i);
      }
      else
      {
         // re-weight
         double askPrice = SymbolInfoDouble(heldCoin, SYMBOL_ASK);
         double cs       = SymbolInfoDouble(heldCoin, SYMBOL_TRADE_CONTRACT_SIZE);
         if(cs<=0) cs=1.0;

         double rawLot   = moneyPerLong / (askPrice*cs);
         double minLot   = SymbolInfoDouble(heldCoin, SYMBOL_VOLUME_MIN);
         double adjLot   = AdjustToVolumeStep(heldCoin, rawLot);
         double oldLot   = currentPositions[i].lotSize;

         if(adjLot<minLot || adjLot<=0)
         {
            Print("Skipped re-weight LONG ", heldCoin, " => volume invalid ", adjLot);
            continue;
         }
         // if difference is big => close & re-open
         if(MathAbs(adjLot - oldLot)>1e-6)
         {
            CloseAllPositions(heldCoin);
            ArrayRemove(currentPositions, i);

            if(adjLot>=minLot)
            {
               OpenBuyPosition(heldCoin, adjLot);
               int newPos=ArraySize(currentPositions);
               ArrayResize(currentPositions, newPos+1);
               currentPositions[newPos].symbol=heldCoin;
               currentPositions[newPos].entryPrice=askPrice;
               currentPositions[newPos].lotSize=adjLot;
            }
         }
      }
   }

   //---------------------------------------------------------
   // 2) Re-weight existing SHORT positions
   //---------------------------------------------------------
   for(int i=ArraySize(currentShorts)-1; i>=0; i--)
   {
      string heldCoin   = currentShorts[i].symbol;

      // do we still want this coin SHORT?
      bool stillWanted = false;
      for(int j=0; j<ArraySize(coinsToShort); j++)
      {
         if(heldCoin==coinsToShort[j]) { stillWanted=true; break; }
      }

      if(!stillWanted)
      {
         // close & remove from short array
         CloseAllPositions(heldCoin);
         ArrayRemove(currentShorts, i);
      }
      else
      {
         // re-weight short
         double bidPrice = SymbolInfoDouble(heldCoin, SYMBOL_BID); 
         // In a short, you typically focus on the bid to see how much you get
         // but for re-weighting logic, we can use ask or bid. We'll use ask
         // if you prefer. It's just a reference price.

         double askPrice= SymbolInfoDouble(heldCoin,SYMBOL_ASK);
         double cs      = SymbolInfoDouble(heldCoin,SYMBOL_TRADE_CONTRACT_SIZE);
         if(cs<=0) cs=1.0;

         double rawLot   = moneyPerShort / (askPrice*cs);
         double minLot   = SymbolInfoDouble(heldCoin, SYMBOL_VOLUME_MIN);
         double adjLot   = AdjustToVolumeStep(heldCoin, rawLot);
         double oldLot   = currentShorts[i].lotSize;

         if(adjLot<minLot || adjLot<=0)
         {
            Print("Skipped re-weight SHORT ", heldCoin, " => volume invalid ", adjLot);
            continue;
         }
         if(MathAbs(adjLot - oldLot)>1e-6)
         {
            // close old short
            CloseAllPositions(heldCoin);
            ArrayRemove(currentShorts, i);

            if(adjLot>=minLot)
            {
               // open new short
               OpenShortPosition(heldCoin, adjLot);
               int newPos=ArraySize(currentShorts);
               ArrayResize(currentShorts,newPos+1);
               currentShorts[newPos].symbol=heldCoin;
               currentShorts[newPos].entryPrice=askPrice; 
               currentShorts[newPos].lotSize=adjLot;
            }
         }
      }
   }

   //---------------------------------------------------------
   // 3) Open new LONG positions for newly selected coins
   //---------------------------------------------------------
   for(int i=0; i<ArraySize(coinsToLong); i++)
   {
      string coin = coinsToLong[i];
      // skip if we already hold it
      bool isHeld=false;
      for(int j=0; j<ArraySize(currentPositions); j++)
      {
         if(currentPositions[j].symbol==coin){ isHeld=true; break; }
      }
      if(isHeld) continue;

      // compute lot
      double askPrice=SymbolInfoDouble(coin, SYMBOL_ASK);
      double cs=SymbolInfoDouble(coin,SYMBOL_TRADE_CONTRACT_SIZE);
      if(cs<=0) cs=1.0;

      double rawLot= (moneyPerLong)/(askPrice*cs);
      double minLot= SymbolInfoDouble(coin, SYMBOL_VOLUME_MIN);
      double adjLot= AdjustToVolumeStep(coin, rawLot);

      if(adjLot<minLot || adjLot<=0)
      {
         Print("Skipped new LONG ", coin, " => volume invalid: ", adjLot);
         continue;
      }

      OpenBuyPosition(coin, adjLot);
      int newPos=ArraySize(currentPositions);
      ArrayResize(currentPositions, newPos+1);
      currentPositions[newPos].symbol=coin;
      currentPositions[newPos].entryPrice=askPrice;
      currentPositions[newPos].lotSize=adjLot;
   }

   //---------------------------------------------------------
   // 4) Open new SHORT positions for newly selected coins
   //---------------------------------------------------------
   for(int i=0; i<ArraySize(coinsToShort); i++)
   {
      string coin=coinsToShort[i];
      // skip if we already hold it short
      bool isHeld=false;
      for(int j=0; j<ArraySize(currentShorts); j++)
      {
         if(currentShorts[j].symbol==coin){ isHeld=true; break; }
      }
      if(isHeld) continue;

      double askPrice=SymbolInfoDouble(coin,SYMBOL_ASK);
      double cs=SymbolInfoDouble(coin,SYMBOL_TRADE_CONTRACT_SIZE);
      if(cs<=0) cs=1.0;

      double rawLot= moneyPerShort/(askPrice*cs);
      double minLot= SymbolInfoDouble(coin, SYMBOL_VOLUME_MIN);
      double adjLot= AdjustToVolumeStep(coin, rawLot);

      if(adjLot<minLot || adjLot<=0)
      {
         Print("Skipped new SHORT ", coin, " => volume invalid: ", adjLot);
         continue;
      }

      OpenShortPosition(coin, adjLot);
      int newPos=ArraySize(currentShorts);
      ArrayResize(currentShorts, newPos+1);
      currentShorts[newPos].symbol=coin;
      currentShorts[newPos].entryPrice=askPrice; 
      currentShorts[newPos].lotSize=adjLot;
   }

   //---------------------------------------------------------
   // 5) stop-loss logic for LONGS => if price falls 3%
   //---------------------------------------------------------
   double stopLossPct=InpStopLossPct;
   for(int i=ArraySize(currentPositions)-1; i>=0; i--)
   {
      string sym=currentPositions[i].symbol;
      double entryPrice=currentPositions[i].entryPrice;
      double currentPrice=SymbolInfoDouble(sym, SYMBOL_BID);

      // if drop from entry is over 3%
      if((entryPrice - currentPrice)/entryPrice> stopLossPct)
      {
         Print("Stop-loss triggered for LONG ",sym);
         CloseAllPositions(sym);
         ArrayRemove(currentPositions, i);
      }
   }

   //---------------------------------------------------------
   // 6) stop-loss logic for SHORTS => if price rises 3%
   //---------------------------------------------------------
   for(int i=ArraySize(currentShorts)-1; i>=0; i--)
   {
      string sym = currentShorts[i].symbol;
      double entryPrice= currentShorts[i].entryPrice; 
      double currentAsk= SymbolInfoDouble(sym, SYMBOL_ASK);

      // if currentAsk > entryPrice*(1+ stopLossPct)
      if(currentAsk> entryPrice*(1.0+ stopLossPct))
      {
         Print("Stop-loss triggered for SHORT ", sym);
         CloseAllPositions(sym);
         ArrayRemove(currentShorts, i);
      }
   }
}

//------------------------------------------------------------------//
//        Factor calculations & utility functions                   //
//------------------------------------------------------------------//

double GetMomentumFactor(string sym)
{
   MqlRates rates[];
   int barsNeeded=481;
   int copied=CopyRates(sym,PERIOD_M1,0,barsNeeded,rates);
   if(copied<barsNeeded) return 0;
   double momentum= (rates[0].close / rates[barsNeeded-1].close)-1.0;
   return momentum;
}

double GetVolatilityFactor(string sym)
{
   MqlRates rates[];
   int window=480;
   int copied=CopyRates(sym, PERIOD_M1, 0, window, rates);
   if(copied<window) return 0;

   double sum=0, sumSq=0;
   int count=0;
   for(int i=1; i<copied; i++)
   {
      double ret=MathLog(rates[i].close/rates[i-1].close);
      sum+=ret; sumSq+=ret*ret;
      count++;
   }
   if(count==0)return 0;
   double mean=sum/count;
   double var=(sumSq/count)- (mean*mean);
   return MathSqrt(var);
}

double GetMACDFactor(string sym)
{
   int handle=iMACD(sym,PERIOD_M1,60,180,45,PRICE_CLOSE);
   if(handle==INVALID_HANDLE)return 0;

   double macdBuf[], sigBuf[];
   if(CopyBuffer(handle,0,0,1,macdBuf)<=0)
   {
      IndicatorRelease(handle);
      return 0;
   }
   if(CopyBuffer(handle,1,0,1,sigBuf)<=0)
   {
      IndicatorRelease(handle);
      return 0;
   }
   double val=macdBuf[0]-sigBuf[0];
   IndicatorRelease(handle);
   return val;
}

double GetDonchianFactor(string sym)
{
   MqlRates rates[];
   int barsNeeded=1140;
   int copied=CopyRates(sym,PERIOD_M1,0,barsNeeded,rates);
   if(copied<barsNeeded)return 0;

   double highest=rates[0].high;
   double lowest= rates[0].low;
   for(int i=0; i<copied; i++)
   {
      if(rates[i].high>highest) highest=rates[i].high;
      if(rates[i].low <lowest ) lowest = rates[i].low;
   }
   double c=rates[0].close;
   if(highest<=lowest)return 0;
   return (c -lowest)/(highest -lowest);
}

void NormalizeZScore(double &arr[])
{
   int n=ArraySize(arr);
   if(n==0)return;

   double sum=0, sumSq=0;
   for(int i=0; i<n; i++)
   {
      sum+=arr[i];
      sumSq+=arr[i]*arr[i];
   }
   double mean=sum/n;
   double var=(sumSq/n)-(mean*mean);
   double stddev=(var>0)? MathSqrt(var):1e-10;

   for(int i=0; i<n; i++)
      arr[i]=(arr[i]-mean)/stddev;
}

// Adjust volume to broker's step & range
double AdjustToVolumeStep(string symbol, double volume)
{
   double minLot= SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   double maxLot= SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
   double lotStep=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   if(lotStep<=0) lotStep=0.01;

   double stepped= MathFloor(volume/lotStep)*lotStep;
   // figure out how many decimals to keep
   int digits= (int)MathCeil(-MathLog10(lotStep));
   double adjusted= NormalizeDouble(stepped,digits);

   // clamp to min..max
   if(adjusted>maxLot) adjusted= maxLot;
   if(adjusted<minLot) adjusted= 0.0; 
   return adjusted;
}

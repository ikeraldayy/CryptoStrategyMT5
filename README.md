# Weighted Multi-Factor Crypto Strategy

This repository contains a MetaTrader 5 Expert Advisor implementing a multi-factor cryptocurrency trading strategy. The system dynamically clusters assets and allocates capital based on combined indicator scores, aiming for diversified exposure across uncorrelated coins.

## Strategy Overview

### 1. Clustering for Diversification
- Computes a correlation matrix of returns for 30 cryptocurrencies over a loopback period (e.g. 30 days).
- Applies a clustering algorithm to group cryptos with similar behavior in return space.
- Selects coins from multiple clusters to reduce risk concentration and enhance robustness against idiosyncratic crashes.

### 2. Factor-Based Scoring
Each coin is ranked by a weighted combination of the following signals:

- Momentum (MOMᵢ): 8-hour price momentum.
- Volatility (Volᵢ): Z-score of volatility across coins (lower volatility preferred).
- MACDᵢ: Z-scored MACD signal using:
  - Short EMA = 60 min
  - Long EMA = 180 min
  - Signal line = 45 min
- Donchian Channel (DCᵢ): 24-hour breakout range (n = 1140 min).

The combined score is computed as:

Sᵢ(t) = w₁·MOMᵢ(t) + w₂·Volᵢ(t) + w₃·MACDᵢ(t) + w₄·DCᵢ(t)

### 3. Portfolio Allocation
- Within each cluster:
  - Rank assets by score Sᵢ(t)
  - Go long on the top r assets with equal weight.
- Allocate capital equally across all clusters.

### 4. Partial Hedging
- Hedge total long exposure L by shorting a broad crypto index:
  Hedge position = h × L

### 5. Rebalancing & Stop-Loss
- Strategy rebalances 1–2 times per day.
- Positions are closed early if the price falls beyond a specified threshold relative to the entry price.

---

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';

void main() {
  runApp(const DlcScalperApp());
}

class DlcScalperApp extends StatelessWidget {
  const DlcScalperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HKEX DLC Scalper',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        cardColor: const Color(0xFF161B22),
      ),
      home: const MainScalperScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// МОДЕЛИ ДАННЫХ
// ---------------------------------------------------------------------------

class DlcProduct {
  final String dlcTicker;
  final String underlyingTicker;
  final String dlcName;
  final String direction; // "LONG" или "SHORT"
  final int leverage;
  final double bid;
  final double ask;

  DlcProduct({
    required this.dlcTicker,
    required this.underlyingTicker,
    required this.dlcName,
    required this.direction,
    required this.leverage,
    required this.bid,
    required this.ask,
  });

  double get spreadPercent => ask > 0 ? ((ask - bid) / ask) * 100 : 0.0;
}

enum ExitUrgency { none, warning, takeProfit, stopLoss }

class ExitDecision {
  final ExitUrgency urgency;
  final String title;
  final String reason;
  final double suggestedExitPrice;
  final double currentProfitPercent;

  ExitDecision({
    required this.urgency,
    required this.title,
    required this.reason,
    required this.suggestedExitPrice,
    required this.currentProfitPercent,
  });
}

// ---------------------------------------------------------------------------
// ГЛАВНЫЙ ЭКРАН
// ---------------------------------------------------------------------------

class MainScalperScreen extends StatefulWidget {
  const MainScalperScreen({super.key});

  @override
  State<MainScalperScreen> createState() => _MainScalperScreenState();
}

class _MainScalperScreenState extends State<MainScalperScreen> {
  // Параметры базовой акции (HKEX)
  final String stockTicker = "0700.HK";
  double stockPrice = 382.40;
  double emaFast = 382.40; // EMA 9
  double emaSlow = 382.40; // EMA 21
  final double alphaFast = 2 / (9 + 1);
  final double alphaSlow = 2 / (21 + 1);
  final List<double> priceHistory = [];
  double rsi = 50.0;

  // Каталог актуальных DLC от SocGen на SGX
  final List<DlcProduct> dlcCatalog = [
    DlcProduct(
      dlcTicker: "WK4W",
      underlyingTicker: "0700.HK",
      dlcName: "Tencent 5xLongSG28",
      direction: "LONG",
      leverage: 5,
      bid: 0.420,
      ask: 0.425,
    ),
    DlcProduct(
      dlcTicker: "JLZW",
      underlyingTicker: "0700.HK",
      dlcName: "Tencent 5xShortSG28",
      direction: "SHORT",
      leverage: 5,
      bid: 0.310,
      ask: 0.315,
    ),
  ];

  DlcProduct? recommendedDlc;
  String marketTrend = "WAIT";

  // Состояние сделки
  bool isPositionOpen = false;
  DlcProduct? activeDlc;
  double positionEntryPrice = 0.0;
  double activeDlcCurrentBid = 0.0;
  double positionPeakPrice = 0.0;
  ExitDecision? currentExitDecision;

  Timer? _liveFeedTimer;

  @override
  void initState() {
    super.initState();
    _startMarketSimulation();
  }

  void _startMarketSimulation() {
    _liveFeedTimer = Timer.periodic(const Duration(milliseconds: 1000), (timer) {
      final random = Random();
      final delta = (random.nextDouble() - 0.48) * 0.45;
      final newStockPrice = double.parse((stockPrice + delta).toStringAsFixed(2));

      _processNewTick(newStockPrice);
    });
  }

  void _processNewTick(double newPrice) {
    setState(() {
      stockPrice = newPrice;

      // 1. Расчет скользящих средних
      emaFast = (stockPrice * alphaFast) + (emaFast * (1 - alphaFast));
      emaSlow = (stockPrice * alphaSlow) + (emaSlow * (1 - alphaSlow));

      // 2. Расчет RSI(14)
      priceHistory.add(stockPrice);
      if (priceHistory.length > 14) {
        priceHistory.removeAt(0);
        _calcRsi();
      }

      // 3. Анализ тренда и подбор оптимального DLC
      if (emaFast > emaSlow && rsi < 70) {
        marketTrend = "STRONG BUY";
        recommendedDlc = dlcCatalog.firstWhere((d) => d.direction == "LONG");
      } else if (emaFast < emaSlow && rsi > 30) {
        marketTrend = "STRONG SELL";
        recommendedDlc = dlcCatalog.firstWhere((d) => d.direction == "SHORT");
      } else {
        marketTrend = "WAIT";
      }

      // 4. Обновление цены открытого DLC с плечом 5x
      _updateDlcPrices();

      // 5. Проверка условий выхода (Exit Engine)
      if (isPositionOpen && activeDlc != null) {
        _evaluateExitStrategy();
      }
    });
  }

  void _calcRsi() {
    double gains = 0;
    double losses = 0;
    for (int i = 1; i < priceHistory.length; i++) {
      final diff = priceHistory[i] - priceHistory[i - 1];
      if (diff >= 0) gains += diff;
      else losses += diff.abs();
    }
    if (losses == 0) {
      rsi = 100;
      return;
    }
    final rs = gains / losses;
    rsi = 100 - (100 / (1 + rs));
  }

  void _updateDlcPrices() {
    if (isPositionOpen && activeDlc != null) {
      final diffStockPercent = ((stockPrice - emaSlow) / emaSlow);
      final leverageMultiplier = activeDlc!.direction == "LONG" ? 5 : -5;
      
      activeDlcCurrentBid = double.parse(
        (positionEntryPrice * (1 + (diffStockPercent * leverageMultiplier * 0.05))).toStringAsFixed(3)
      );

      if (activeDlcCurrentBid > positionPeakPrice) {
        positionPeakPrice = activeDlcCurrentBid;
      }
    }
  }

  void _evaluateExitStrategy() {
    final profitPercent = ((activeDlcCurrentBid - positionEntryPrice) / positionEntryPrice) * 100;
    final trailingCutoff = positionPeakPrice * 0.97; // 3% откат от пика

    // Трейлинг-стоп (защита прибыли)
    if (positionPeakPrice > positionEntryPrice * 1.03 && activeDlcCurrentBid <= trailingCutoff) {
      currentExitDecision = ExitDecision(
        urgency: ExitUrgency.takeProfit,
        title: "СБРОС ПО ТРЕЙЛИНГУ",
        reason: "Откат на 3% от пика S\$${positionPeakPrice.toStringAsFixed(3)}. Фиксируйте прибыль.",
        suggestedExitPrice: activeDlcCurrentBid,
        currentProfitPercent: profitPercent,
      );
      return;
    }

    // Стоп-лосс
    if (profitPercent <= -4.0) {
      currentExitDecision = ExitDecision(
        urgency: ExitUrgency.stopLoss,
        title: "СТОП-ЛОСС (-4%)",
        reason: "Импульс сломался. Режьте убыток для сохранения капитала.",
        suggestedExitPrice: activeDlcCurrentBid,
        currentProfitPercent: profitPercent,
      );
      return;
    }

    // Затухание импульса по RSI
    if (activeDlc!.direction == "LONG" && rsi > 72) {
      currentExitDecision = ExitDecision(
        urgency: ExitUrgency.takeProfit,
        title: "ИМПУЛЬС ИССЯК (RSI > 72)",
        reason: "Акция перекуплена. Высокий риск резкого отката.",
        suggestedExitPrice: activeDlcCurrentBid,
        currentProfitPercent: profitPercent,
      );
      return;
    } else if (activeDlc!.direction == "SHORT" && rsi < 28) {
      currentExitDecision = ExitDecision(
        urgency: ExitUrgency.takeProfit,
        title: "ИМПУЛЬС ИССЯК (RSI < 28)",
        reason: "Акция перепродана. Вероятен отскок цены вверх.",
        suggestedExitPrice: activeDlcCurrentBid,
        currentProfitPercent: profitPercent,
      );
      return;
    }

    // Удержание позиции
    currentExitDecision = ExitDecision(
      urgency: ExitUrgency.none,
      title: "ДЕРЖИМ ПОЗИЦИЮ",
      reason: "Тренд в силе, импульс продолжается.",
      suggestedExitPrice: activeDlcCurrentBid,
      currentProfitPercent: profitPercent,
    );
  }

  void _openPosition(DlcProduct dlc) {
    setState(() {
      isPositionOpen = true;
      activeDlc = dlc;
      positionEntryPrice = dlc.ask;
      activeDlcCurrentBid = dlc.ask;
      positionPeakPrice = dlc.ask;
      currentExitDecision = null;
    });
  }

  void _closePosition() {
    setState(() {
      isPositionOpen = false;
      activeDlc = null;
      currentExitDecision = null;
    });
  }

  @override
  void dispose() {
    _liveFeedTimer?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // ВИДЖЕТЫ ИНТЕРФЕЙСА
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    Color trendColor = Colors.grey;
    if (marketTrend == "STRONG BUY") trendColor = const Color(0xFF00E676);
    if (marketTrend == "STRONG SELL") trendColor = const Color(0xFFFF5252);

    return Scaffold(
      appBar: AppBar(
        title: Text("Scalp Engine: $stockTicker"),
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text(
                "HK\$ ${stockPrice.toStringAsFixed(2)}",
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          )
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _buildMetricBox("EMA 9", emaFast.toStringAsFixed(2), Colors.cyanAccent),
                const SizedBox(width: 8),
                _buildMetricBox("EMA 21", emaSlow.toStringAsFixed(2), Colors.amberAccent),
                const SizedBox(width: 8),
                _buildMetricBox("RSI (14)", rsi.toStringAsFixed(1), rsi > 70 ? Colors.redAccent : (rsi < 30 ? Colors.greenAccent : Colors.white)),
              ],
            ),
            const SizedBox(height: 16),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: trendColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: trendColor, width: 1.5),
              ),
              child: Row(
                children: [
                  Icon(
                    marketTrend == "STRONG BUY"
                        ? Icons.trending_up
                        : (marketTrend == "STRONG SELL" ? Icons.trending_down : Icons.pause),
                    color: trendColor,
                    size: 30,
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "ТРЕНД АКЦИИ: $marketTrend",
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: trendColor),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        marketTrend == "STRONG BUY"
                            ? "Быстрая средняя выше медленной, импульс вверх"
                            : (marketTrend == "STRONG SELL" ? "Импульс вниз, давление продавцов" : "Боковик, ждем импульса"),
                        style: const TextStyle(fontSize: 12, color: Colors.white60),
                      )
                    ],
                  )
                ],
              ),
            ),
            const SizedBox(height: 20),

            if (isPositionOpen && activeDlc != null) ...[
              const Text("ОТКРЫТАЯ ПОЗИЦИЯ DLC", style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              _buildActivePositionCard(),
              const SizedBox(height: 12),
              if (currentExitDecision != null && currentExitDecision!.urgency != ExitUrgency.none)
                _buildExitBanner(currentExitDecision!),
            ] else ...[
              const Text("РЕКОМЕНДАЦИЯ К ПОКУПКЕ (SOCGEN SGX)", style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (recommendedDlc != null && marketTrend != "WAIT")
                _buildRecommendationCard(recommendedDlc!)
              else
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161B22),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Center(
                    child: Text("Ожидание четкого импульса для подбора DLC...", style: TextStyle(color: Colors.white38)),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMetricBox(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          children: [
            Text(label, style: const TextStyle(fontSize: 11, color: Colors.white54)),
            const SizedBox(height: 4),
            Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _buildRecommendationCard(DlcProduct dlc) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "${dlc.dlcTicker} • ${dlc.leverage}x ${dlc.direction}",
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: dlc.direction == "LONG" ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  "СПРЕД ${dlc.spreadPercent.toStringAsFixed(2)}%",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: dlc.direction == "LONG" ? Colors.greenAccent : Colors.redAccent,
                  ),
                ),
              )
            ],
          ),
          const SizedBox(height: 6),
          Text(dlc.dlcName, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          const Divider(color: Colors.white10, height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Цена Ask (SGX)", style: TextStyle(color: Colors.white38, fontSize: 11)),
                  Text("S\$ ${dlc.ask.toStringAsFixed(3)}", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
              ElevatedButton.icon(
                onPressed: () => _openPosition(dlc),
                icon: const Icon(Icons.flash_on, size: 18),
                label: const Text("ВОЙТИ В СДЕЛКУ"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: dlc.direction == "LONG" ? const Color(0xFF00E676) : const Color(0xFFFF5252),
                  foregroundColor: Colors.black,
                  textStyle: const TextStyle(fontWeight: FontWeight.bold),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: BorderRadius.circular(10),
                ),
              )
            ],
          )
        ],
      ),
    );
  }

  Widget _buildActivePositionCard() {
    final profit = ((activeDlcCurrentBid - positionEntryPrice) / positionEntryPrice) * 100;
    final profitColor = profit >= 0 ? const Color(0xFF00E676) : const Color(0xFFFF5252);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: profitColor.withOpacity(0.6), width: 1.5),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text("${activeDlc!.dlcTicker} (${activeDlc!.direction})", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Text(
                "${profit >= 0 ? '+' : ''}${profit.toStringAsFixed(2)}%",
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: profitColor),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text("Вход: S\$ ${positionEntryPrice.toStringAsFixed(3)}", style: const TextStyle(color: Colors.white60)),
              Text("Текущий Bid: S\$ ${activeDlcCurrentBid.toStringAsFixed(3)}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              Text("Пик: S\$ ${positionPeakPrice.toStringAsFixed(3)}", style: const TextStyle(color: Colors.amberAccent)),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _closePosition,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.white30),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: const Text("ЗАКРЫТЬ ПОЗИЦИЮ ВРУЧНУЮ"),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildExitBanner(ExitDecision decision) {
    Color bannerColor = decision.urgency == ExitUrgency.takeProfit ? const Color(0xFF00E676) : const Color(0xFFFF1744);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bannerColor.withOpacity(0.18),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: bannerColor, width: 2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(decision.urgency == ExitUrgency.takeProfit ? Icons.check_circle : Icons.warning_rounded, color: bannerColor, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(decision.title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: bannerColor)),
                const SizedBox(height: 4),
                Text(decision.reason, style: const TextStyle(fontSize: 13, color: Colors.white70)),
                const SizedBox(height: 6),
                Text("Выход по рынку: S\$ ${decision.suggestedExitPrice.toStringAsFixed(3)}", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ],
            ),
          )
        ],
      ),
    );
  }
}

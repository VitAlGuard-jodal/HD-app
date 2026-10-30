import 'dart:math' as math;

double rmsToDbfs(int rms) =>
    rms <= 0 ? double.negativeInfinity : 20 * math.log(rms / 32768) / math.ln10;
double dbfsToLevel(double dbfs) =>
    ((dbfs + 60) / 60).clamp(0.0, 1.0).toDouble();

// VSBeatCore.hpp
// Lõi phân tích nhạc: không phụ thuộc framework nào -> build được cả trên Mac/Linux để test.
//
//  PCM mono  ->  STFT (Hann, radix-2)  ->  log-mel  ->  SuperFlux onset envelope
//            ->  tempo (autocorr + log-gauss prior)  ->  DP beat tracker (Ellis)
//            ->  hit picker (adaptive threshold)     ->  PCM refine (attack start, kick-lock)
//            ->  downbeat phase + event selection (grid / hits / hybrid)
#pragma once

#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdint>
#include <functional>
#include <limits>
#include <numeric>
#include <vector>

namespace vsbeat {

// ───────────────────────────── Config & kết quả ─────────────────────────────

struct Config {
    double sampleRate   = 22050.0;
    int    fftSize      = 1024;
    int    hop          = 256;
    int    melBands     = 48;
    double fMin         = 30.0;
    double fMax         = 9000.0;
    double minBPM       = 60.0;
    double maxBPM       = 200.0;
    double priorBPM     = 125.0;   // nhạc edit/TikTok hay quanh 100-150
    double priorOctaves = 1.25;    // độ rộng prior (log2)
    double tightness    = 90.0;    // DP: càng lớn càng bám nhịp đều
    double lowBoost     = 1.8;     // nhấn dải bass (tiếng kick)
    double tempoScale   = 1.0;     // 0.5 = half-time, 2 = double-time
    double tempoHint    = 0.0;     // >0: ép BPM này
    double refineWindow = 0.055;   // giây, cửa sổ chỉnh theo PCM
    bool   refinePCM    = true;
    bool   kickLock     = true;
};

struct Event {
    double time     = 0;   // giây
    double strength = 0;   // 0..1 (tương đối trong bài)
    bool   grid     = false;
    bool   downbeat = false;
};

struct Result {
    double bpm        = 0;
    double tempoConf  = 0;     // 0..1
    double musicScore = 0;     // 0..1  (có nhạc nhịp rõ hay không)
    double rmsDb      = -120;
    double duration   = 0;
    double hopSec     = 0;
    int    barPhase   = 0;     // beat index % 4 là phách mạnh
    std::vector<Event> beats;  // lưới nhịp từ DP
    std::vector<Event> hits;   // transient mạnh (kể cả lệch nhịp)
    std::vector<float> onset;  // envelope đã chuẩn hóa (debug / UI)
};

enum class Mode { Grid, Hits, Hybrid };

struct SelectOptions {
    Mode   mode        = Mode::Hybrid;
    int    groupEvery  = 1;      // 1 = mọi beat, 2, 4 (ô nhịp), 8
    double sensitivity = 1.0;    // 0.5..2.0
    double minGap      = 0.18;   // giây
    double edgeMargin  = 0.12;   // bỏ điểm sát đầu/cuối
    size_t maxEvents   = 0;      // 0 = không giới hạn
};

using ProgressFn = std::function<bool(float)>;   // trả false => hủy

// ───────────────────────────── FFT radix-2 ─────────────────────────────

class FFT {
public:
    explicit FFT(int n) : n_(n), rev_(n), tw_(n / 2) {
        int lg = 0;
        while ((1 << lg) < n) ++lg;
        for (int i = 0; i < n; ++i) {
            int r = 0;
            for (int b = 0; b < lg; ++b)
                if (i & (1 << b)) r |= 1 << (lg - 1 - b);
            rev_[i] = r;
        }
        for (int i = 0; i < n / 2; ++i) {
            double a = -2.0 * M_PI * i / n;
            tw_[i] = { static_cast<float>(std::cos(a)), static_cast<float>(std::sin(a)) };
        }
    }
    void forward(std::vector<std::complex<float>>& x) const {
        for (int i = 0; i < n_; ++i)
            if (i < rev_[i]) std::swap(x[i], x[rev_[i]]);
        for (int size = 2; size <= n_; size <<= 1) {
            int half = size >> 1, step = n_ / size;
            for (int i = 0; i < n_; i += size) {
                for (int j = 0; j < half; ++j) {
                    const std::complex<float> w = tw_[j * step];
                    const std::complex<float> a = x[i + j], b = x[i + j + half];
                    const std::complex<float> t(b.real() * w.real() - b.imag() * w.imag(),
                                                b.real() * w.imag() + b.imag() * w.real());
                    x[i + j]        = a + t;
                    x[i + j + half] = a - t;
                }
            }
        }
    }
private:
    int n_;
    std::vector<int> rev_;
    std::vector<std::complex<float>> tw_;
};

// ───────────────────────────── tiện ích nhỏ ─────────────────────────────

namespace detail {

inline double hzToMel(double f) { return 2595.0 * std::log10(1.0 + f / 700.0); }
inline double melToHz(double m) { return 700.0 * (std::pow(10.0, m / 2595.0) - 1.0); }
inline double clamp(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }
inline double sat(double x) { return x <= 0 ? 0 : (x >= 1 ? 1 : x); }

inline double median(std::vector<double> v) {
    if (v.empty()) return 0;
    size_t m = v.size() / 2;
    std::nth_element(v.begin(), v.begin() + m, v.end());
    return v[m];
}

struct MelBank {
    struct Band { int start = 0; std::vector<float> w; double fc = 0; };
    std::vector<Band> bands;

    MelBank(const Config& c) {
        const int bins = c.fftSize / 2 + 1;
        const double binHz = c.sampleRate / c.fftSize;
        const double mLo = hzToMel(c.fMin), mHi = hzToMel(std::min(c.fMax, c.sampleRate * 0.5));
        std::vector<double> pts(c.melBands + 2);
        for (int i = 0; i < c.melBands + 2; ++i)
            pts[i] = melToHz(mLo + (mHi - mLo) * i / (c.melBands + 1));
        for (int b = 0; b < c.melBands; ++b) {
            Band band;
            const double lo = pts[b], ce = pts[b + 1], hi = pts[b + 2];
            band.fc = ce;
            int k0 = std::max(0, (int)std::ceil(lo / binHz));
            int k1 = std::min(bins - 1, (int)std::floor(hi / binHz));
            band.start = k0;
            double sum = 0;
            for (int k = k0; k <= k1; ++k) {
                double f = k * binHz;
                double w = f <= ce ? (f - lo) / std::max(1e-9, ce - lo)
                                   : (hi - f) / std::max(1e-9, hi - ce);
                w = std::max(0.0, w);
                band.w.push_back((float)w);
                sum += w;
            }
            if (band.w.empty() || sum <= 1e-9) {          // dải quá hẹp: lấy bin gần nhất
                int k = std::min(bins - 1, std::max(0, (int)std::lround(ce / binHz)));
                band.start = k; band.w.assign(1, 1.f); sum = 1;
            }
            for (auto& w : band.w) w = (float)(w / sum);
            bands.push_back(std::move(band));
        }
    }
};

// Envelope thời gian ~1ms (RMS 3ms) cho wideband và low-pass ~180Hz.
struct FineEnv {
    std::vector<float> broad, low;
    double rate = 0;
    int    step = 0;
};

inline FineEnv buildFineEnv(const std::vector<float>& pcm, double sr) {
    FineEnv e;
    e.step = std::max(8, (int)std::lround(sr / 1000.0));
    e.rate = sr / e.step;
    const int win = e.step * 3;
    const size_t n = pcm.size();
    const size_t blocks = n / e.step;
    e.broad.assign(blocks, 0.f);
    e.low.assign(blocks, 0.f);

    // 2 tầng one-pole low-pass ~180Hz
    const double a = 1.0 - std::exp(-2.0 * M_PI * 180.0 / sr);
    std::vector<float> lp(n);
    double y1 = 0, y2 = 0;
    for (size_t i = 0; i < n; ++i) {
        y1 += a * (pcm[i] - y1);
        y2 += a * (y1 - y2);
        lp[i] = (float)y2;
    }
    // trượt tổng bình phương bằng prefix sums
    std::vector<double> pb(n + 1, 0.0), pl(n + 1, 0.0);
    for (size_t i = 0; i < n; ++i) {
        pb[i + 1] = pb[i] + (double)pcm[i] * pcm[i];
        pl[i + 1] = pl[i] + (double)lp[i] * lp[i];
    }
    for (size_t k = 0; k < blocks; ++k) {
        long c = (long)(k * e.step + e.step / 2);
        long s = std::max(0L, c - win / 2), t = std::min((long)n, c + win / 2);
        double len = std::max(1L, t - s);
        e.broad[k] = (float)std::sqrt((pb[t] - pb[s]) / len);
        e.low[k]   = (float)std::sqrt((pl[t] - pl[s]) / len);
    }
    return e;
}

// Tìm điểm bắt đầu cú đập quanh tCoarse. Trả về <0 nếu không tin cậy.
inline double refineOnset(const FineEnv& e, double tCoarse, double halfWin, bool kickLock) {
    if (e.broad.empty()) return -1;
    const long c = (long)std::llround(tCoarse * e.rate);
    const long W = std::max(4L, (long)std::llround(halfWin * e.rate));
    const long lo = std::max(0L, c - W), hi = std::min((long)e.broad.size() - 1, c + W);
    if (hi - lo < 6) return -1;

    float pb = 0, pl = 0;
    for (long k = lo; k <= hi; ++k) { pb = std::max(pb, e.broad[k]); pl = std::max(pl, e.low[k]); }
    if (pb < 1e-5f) return -1;
    const std::vector<float>& env = (kickLock && pl > 0.30f * pb) ? e.low : e.broad;

    // đỉnh, ưu tiên gần điểm thô
    long p = lo; double best = -1;
    for (long k = lo; k <= hi; ++k) {
        double w = 1.0 - 0.45 * std::abs((double)(k - c)) / (double)W;
        double v = env[k] * w;
        if (v > best) { best = v; p = k; }
    }
    const float peak = env[p];
    if (peak < 1e-5f) return -1;

    // lùi về đầu cú đập: env còn giảm khi lùi và > 18% đỉnh
    long k = p;
    while (k > lo && env[k - 1] <= env[k] && env[k - 1] > 0.18f * peak) --k;
    return (double)k / e.rate;
}

} // namespace detail

// ───────────────────────────── Phân tích chính ─────────────────────────────

inline Result analyze(const std::vector<float>& pcm, const Config& cfg, const ProgressFn& progress = nullptr) {
    using namespace detail;
    Result R;
    const double sr = cfg.sampleRate;
    const int N = cfg.fftSize, H = cfg.hop;
    R.hopSec   = H / sr;
    R.duration = pcm.size() / sr;
    if (pcm.size() < (size_t)(sr * 2.0)) return R;            // < 2s thì bỏ

    auto tick = [&](float p) { return !progress || progress(p); };

    // RMS tổng
    {
        double s = 0;
        for (float v : pcm) s += (double)v * v;
        double rms = std::sqrt(s / pcm.size());
        R.rmsDb = 20.0 * std::log10(std::max(1e-9, rms));
    }
    if (R.rmsDb < -62.0) return R;                           // im lặng

    // ── 1. STFT -> log-mel
    FFT fft(N);
    MelBank mel(cfg);
    const int B = (int)mel.bands.size();
    std::vector<float> window(N);
    for (int i = 0; i < N; ++i) window[i] = 0.5f - 0.5f * (float)std::cos(2.0 * M_PI * i / N);
    const float magScale = 4.0f / N;                         // sin biên độ A -> |X| = A

    const long frames = 1 + ((long)pcm.size() - N) / H;
    std::vector<float> lm((size_t)frames * B);
    std::vector<std::complex<float>> buf(N);
    for (long t = 0; t < frames; ++t) {
        const float* x = pcm.data() + (size_t)t * H;
        for (int i = 0; i < N; ++i) buf[i] = { x[i] * window[i], 0.f };
        fft.forward(buf);
        for (int b = 0; b < B; ++b) {
            const auto& bd = mel.bands[b];
            float acc = 0;
            for (size_t k = 0; k < bd.w.size(); ++k) acc += bd.w[k] * std::abs(buf[bd.start + k]);
            lm[(size_t)t * B + b] = std::log1p(120.0f * acc * magScale);
        }
        if ((t & 511) == 0 && !tick(0.35f * (float)t / frames)) return Result();
    }

    // ── 2. SuperFlux onset envelope (max-filter chống vibrato), nhấn dải bass
    std::vector<float> wBand(B);
    for (int b = 0; b < B; ++b)
        wBand[b] = 1.0f + (float)(cfg.lowBoost - 1.0) * std::exp(-(float)mel.bands[b].fc / 250.0f);

    const int lag = 2;
    std::vector<double> env(frames, 0.0);
    for (long t = 1; t < frames; ++t) {
        const float* cur = &lm[(size_t)t * B];
        const float* ref = &lm[(size_t)std::max(0L, t - lag) * B];
        double s = 0;
        for (int b = 0; b < B; ++b) {
            float m = ref[b];
            if (b > 0)     m = std::max(m, ref[b - 1]);
            if (b < B - 1) m = std::max(m, ref[b + 1]);
            float d = cur[b] - m;
            if (d > 0) s += d * wBand[b];
        }
        env[t] = s;
    }
    if (!tick(0.45f)) return Result();

    // bỏ nền trung bình cục bộ (±0.5s), chuẩn hóa theo độ lệch
    const double fps = sr / H;
    {
        const long Hh = std::max(2L, (long)std::llround(0.5 * fps));
        std::vector<double> pre(frames + 1, 0.0);
        for (long i = 0; i < frames; ++i) pre[i + 1] = pre[i] + env[i];
        std::vector<double> out(frames);
        double ss = 0;
        for (long i = 0; i < frames; ++i) {
            long a = std::max(0L, i - Hh), z = std::min(frames, i + Hh + 1);
            double mean = (pre[z] - pre[a]) / (z - a);
            out[i] = std::max(0.0, env[i] - mean);
            ss += out[i] * out[i];
        }
        double sd = std::sqrt(ss / frames) + 1e-9;
        for (long i = 0; i < frames; ++i) env[i] = out[i] / sd;
    }
    R.onset.assign(env.begin(), env.end());

    // ── 3. Tempo
    const double Lmin = fps * 60.0 / cfg.maxBPM, Lmax = fps * 60.0 / cfg.minBPM;
    const long maxLag = std::min<long>(frames / 2, (long)std::ceil(Lmax * 4.0) + 2);
    std::vector<double> ac(maxLag + 1, 0.0);
    {
        double mean = std::accumulate(env.begin(), env.end(), 0.0) / frames;
        std::vector<double> x(frames);
        for (long i = 0; i < frames; ++i) x[i] = env[i] - mean;
        for (long L = 1; L <= maxLag; ++L) {
            double s = 0;
            for (long i = 0; i + L < frames; ++i) s += x[i] * x[i + L];
            ac[L] = s / (double)(frames - L);
        }
    }
    auto acAt = [&](double L) {
        long i = (long)std::floor(L); double f = L - i;
        if (i < 1 || i + 1 > maxLag) return 0.0;
        return ac[i] * (1 - f) + ac[i + 1] * f;
    };
    const double Lprior = fps * 60.0 / cfg.priorBPM;
    double period = 0, bestScore = -1, meanScore = 0; int cnt = 0;
    for (long L = (long)std::floor(Lmin); L <= (long)std::ceil(Lmax); ++L) {
        double s = acAt(L) + 0.5 * acAt(2.0 * L) + 0.25 * acAt(4.0 * L);
        double lg = std::log2(L / Lprior) / cfg.priorOctaves;
        double prior = std::exp(-0.5 * lg * lg);
        s = std::max(0.0, s) * prior;
        meanScore += s; ++cnt;
        if (s > bestScore) { bestScore = s; period = (double)L; }
    }
    meanScore /= std::max(1, cnt);
    if (period <= 0) return R;
    {   // parabol trên ac thô để lấy lag lẻ
        long L = (long)period;
        if (L > 1 && L < maxLag) {
            double a = ac[L - 1], b = ac[L], c = ac[L + 1], den = a - 2 * b + c;
            if (std::abs(den) > 1e-12) period = L + clamp(0.5 * (a - c) / den, -1.0, 1.0);
        }
    }
    if (cfg.tempoHint > 0) period = fps * 60.0 / cfg.tempoHint;
    period /= std::max(0.25, cfg.tempoScale);
    period = std::max(6.0, period);
    R.bpm       = 60.0 * fps / period;
    R.tempoConf = sat((bestScore / (meanScore + 1e-9) - 1.0) / 3.0);
    if (!tick(0.55f)) return Result();

    // ── 4. DP beat tracking (Ellis 2007)
    std::vector<double> local(frames);
    {   // làm mượt nhẹ (Gaussian sigma ~1 frame)
        const double k[5] = { 0.06, 0.24, 0.40, 0.24, 0.06 };
        for (long i = 0; i < frames; ++i) {
            double s = 0;
            for (int j = -2; j <= 2; ++j) {
                long q = i + j; if (q < 0 || q >= frames) continue;
                s += k[j + 2] * env[q];
            }
            local[i] = s;
        }
    }
    std::vector<double> cum(frames, 0.0);
    std::vector<long>   back(frames, -1);
    const long jLo = (long)std::llround(period * 0.5), jHi = (long)std::llround(period * 2.0);
    for (long i = 0; i < frames; ++i) {
        double best = -std::numeric_limits<double>::infinity(); long arg = -1;
        for (long d = jLo; d <= jHi; ++d) {
            long j = i - d; if (j < 0) break;
            double lr = std::log((double)d / period);
            double v = cum[j] - cfg.tightness * lr * lr;
            if (v > best) { best = v; arg = j; }
        }
        if (arg < 0) { cum[i] = local[i]; back[i] = -1; }
        else         { cum[i] = local[i] + best; back[i] = arg; }
        if ((i & 2047) == 0 && !tick(0.55f + 0.25f * (float)i / frames)) return Result();
    }
    // điểm cuối: cực đại cục bộ cuối cùng đủ lớn
    std::vector<long> maxima;
    std::vector<double> mv;
    for (long i = 1; i + 1 < frames; ++i)
        if (cum[i] > cum[i - 1] && cum[i] >= cum[i + 1]) { maxima.push_back(i); mv.push_back(cum[i]); }
    if (maxima.empty()) return R;
    const double thr = 0.5 * median(mv);
    long tail = maxima.back();
    for (long q = (long)maxima.size() - 1; q >= 0; --q)
        if (cum[maxima[q]] >= thr) { tail = maxima[q]; break; }
    std::vector<long> bf;
    for (long i = tail; i >= 0; i = back[i]) { bf.push_back(i); if (back[i] < 0) break; }
    std::reverse(bf.begin(), bf.end());

    // cắt beat yếu ở đầu/đuôi
    {
        std::vector<double> s(bf.size());
        for (size_t i = 0; i < bf.size(); ++i) s[i] = env[bf[i]];
        double rms = 0; for (double v : s) rms += v * v; rms = std::sqrt(rms / std::max<size_t>(1, s.size()));
        double cut = 0.5 * rms;
        size_t a = 0, z = bf.size();
        while (a < z && s[a] < cut) ++a;
        while (z > a && s[z - 1] < cut) --z;
        bf = std::vector<long>(bf.begin() + a, bf.begin() + z);
    }

    // ── 5. snap + refine theo PCM
    detail::FineEnv fine;
    if (cfg.refinePCM) fine = buildFineEnv(pcm, sr);
    const double coarseLatency = N * 0.5 / sr;       // tâm cửa sổ
    auto frameToTime = [&](double fi, double strengthPeak) {
        (void)strengthPeak;
        double tc = fi * H / sr + coarseLatency;
        if (cfg.refinePCM) {
            double r = refineOnset(fine, tc, cfg.refineWindow, cfg.kickLock);
            if (r >= 0 && std::abs(r - tc) <= cfg.refineWindow * 1.02) return r;
        }
        return tc - 0.012;                              // bù trễ trung bình khi không refine
    };
    auto snapFrame = [&](long f0, int rad) {
        long b = f0; double v = -1;
        for (long i = std::max(0L, f0 - rad); i <= std::min(frames - 1, f0 + rad); ++i)
            if (env[i] > v) { v = env[i]; b = i; }
        double fi = (double)b;
        if (b > 0 && b + 1 < frames) {
            double a = env[b - 1], m = env[b], c = env[b + 1], den = a - 2 * m + c;
            if (std::abs(den) > 1e-9) fi += clamp(0.5 * (a - c) / den, -0.5, 0.5);
        }
        return std::make_pair(fi, env[b]);
    };

    double maxStrength = 1e-9;
    for (long f : bf) {
        auto [fi, st] = snapFrame(f, 2);
        Event e; e.grid = true; e.time = frameToTime(fi, st); e.strength = st;
        R.beats.push_back(e);
        maxStrength = std::max(maxStrength, st);
    }
    if (!tick(0.85f)) return Result();

    // ── 6. Hits (transient mạnh, kể cả lệch nhịp)
    {
        const long rad = std::max(2L, (long)std::llround(0.045 * fps));
        const long W = std::max(8L, (long)std::llround(1.0 * fps));
        std::vector<double> p1(frames + 1, 0.0), p2(frames + 1, 0.0);
        for (long i = 0; i < frames; ++i) { p1[i + 1] = p1[i] + env[i]; p2[i + 1] = p2[i] + env[i] * env[i]; }
        std::vector<long> cand;
        for (long i = 1; i + 1 < frames; ++i) {
            long a = std::max(0L, i - rad), z = std::min(frames - 1, i + rad);
            bool peak = true;
            for (long j = a; j <= z && peak; ++j)
                if (j != i && (env[j] > env[i] || (env[j] == env[i] && j < i))) peak = false;
            if (!peak) continue;
            long wa = std::max(0L, i - W), wz = std::min(frames, i + W + 1);
            double n = wz - wa, mean = (p1[wz] - p1[wa]) / n;
            double var = std::max(0.0, (p2[wz] - p2[wa]) / n - mean * mean);
            double th = mean + 1.0 * std::sqrt(var);
            if (env[i] >= std::max(0.8, th)) cand.push_back(i);
        }
        double hMax = 1e-9;
        for (long i : cand) hMax = std::max(hMax, env[i]);
        for (long i : cand) {
            auto [fi, st] = snapFrame(i, 1);
            Event e; e.grid = false; e.time = frameToTime(fi, st); e.strength = st;
            R.hits.push_back(e);
            maxStrength = std::max(maxStrength, st);
        }
    }
    for (auto& e : R.beats) e.strength = sat(e.strength / maxStrength);
    for (auto& e : R.hits)  e.strength = sat(e.strength / maxStrength);

    // ── 7. Phách mạnh (bar phase theo mod 4)
    if (R.beats.size() >= 8) {
        double best = -1; int bp = 0;
        for (int p = 0; p < 4; ++p) {
            double s = 0; int c = 0;
            for (size_t i = p; i < R.beats.size(); i += 4) { s += R.beats[i].strength; ++c; }
            s /= std::max(1, c);
            if (s > best) { best = s; bp = p; }
        }
        R.barPhase = bp;
        for (size_t i = bp; i < R.beats.size(); i += 4) R.beats[i].downbeat = true;
    }

    // ── 8. Điểm "có nhạc": độ nổi của tempo + độ ăn khớp hits với lưới nhịp
    {
        double prom = sat((bestScore / (meanScore + 1e-9) - 1.0) / 4.0);
        double onGrid = 0, tot = 0;
        for (const auto& h : R.hits) {
            double d = 1e9;
            for (const auto& b : R.beats) d = std::min(d, std::abs(h.time - b.time));
            tot += h.strength;
            if (d < 0.06) onGrid += h.strength;
        }
        double sync = tot > 0 ? onGrid / tot : 0;
        double reg = 0;                                   // độ đều của IBI
        if (R.beats.size() > 4) {
            std::vector<double> ibi;
            for (size_t i = 1; i < R.beats.size(); ++i) ibi.push_back(R.beats[i].time - R.beats[i - 1].time);
            double mu = std::accumulate(ibi.begin(), ibi.end(), 0.0) / ibi.size(), v = 0;
            for (double x : ibi) v += (x - mu) * (x - mu);
            double cv = std::sqrt(v / ibi.size()) / std::max(1e-6, mu);
            reg = sat(1.0 - cv * 4.0);
        }
        double loud = sat((R.rmsDb + 58.0) / 20.0);
        R.musicScore = (0.40 * prom + 0.35 * sync + 0.25 * reg) * (0.4 + 0.6 * loud);
    }
    tick(1.0f);
    return R;
}

// ───────────────────────────── Chọn điểm cắt ─────────────────────────────

inline std::vector<Event> selectEvents(const Result& R, const SelectOptions& o) {
    using namespace detail;
    std::vector<Event> out;
    const double secPerBeat = R.bpm > 1 ? 60.0 / R.bpm : 0.5;

    // nhóm theo ô nhịp: chọn pha khớp phách mạnh nhất cho từng bội số
    std::vector<Event> grid;
    if (o.mode != Mode::Hits) {
        int g = std::max(1, o.groupEvery);
        int phase = 0;
        if (g > 1 && R.beats.size() >= (size_t)(2 * g)) {
            double best = -1;
            for (int p = 0; p < g; ++p) {
                double s = 0; int c = 0;
                for (size_t i = p; i < R.beats.size(); i += g) { s += R.beats[i].strength; ++c; }
                s /= std::max(1, c);
                if (s > best) { best = s; phase = p; }
            }
        }
        for (size_t i = 0; i < R.beats.size(); ++i)
            if (g == 1 || (int)((i + g - phase) % g) == 0) grid.push_back(R.beats[i]);
    }
    std::vector<Event> hits;
    if (o.mode != Mode::Grid) {
        double sens = clamp(o.sensitivity, 0.3, 3.0);
        std::vector<double> st;
        for (const auto& h : R.hits) st.push_back(h.strength);
        double med = median(st);
        double need = (o.mode == Mode::Hits) ? 0.10 / sens : std::max(0.22, 1.15 * med) / sens;
        for (const auto& h : R.hits) {
            if (h.strength < need) continue;
            if (o.mode == Mode::Hybrid) {   // chỉ nhận hit nằm lệch lưới nhịp
                double d = 1e9;
                for (const auto& b : R.beats) d = std::min(d, std::abs(h.time - b.time));
                if (d < 0.32 * secPerBeat) continue;
            }
            hits.push_back(h);
        }
    }
    out.insert(out.end(), grid.begin(), grid.end());
    out.insert(out.end(), hits.begin(), hits.end());
    std::sort(out.begin(), out.end(), [](const Event& a, const Event& b) { return a.time < b.time; });

    // lề đầu/cuối
    out.erase(std::remove_if(out.begin(), out.end(), [&](const Event& e) {
        return e.time < o.edgeMargin || e.time > R.duration - o.edgeMargin;
    }), out.end());

    // gộp điểm quá gần: giữ điểm mạnh hơn (ưu tiên grid khi hòa)
    std::vector<size_t> order(out.size());
    std::iota(order.begin(), order.end(), 0);
    std::sort(order.begin(), order.end(), [&](size_t a, size_t b) {
        double sa = out[a].strength + (out[a].grid ? 0.05 : 0), sb = out[b].strength + (out[b].grid ? 0.05 : 0);
        return sa > sb;
    });
    std::vector<char> keep(out.size(), 0);
    std::vector<double> taken;
    for (size_t idx : order) {
        bool ok = true;
        for (double t : taken) if (std::abs(t - out[idx].time) < o.minGap) { ok = false; break; }
        if (ok) { keep[idx] = 1; taken.push_back(out[idx].time); }
    }
    std::vector<Event> fin;
    for (size_t i = 0; i < out.size(); ++i) if (keep[i]) fin.push_back(out[i]);

    if (o.maxEvents > 0 && fin.size() > o.maxEvents) {
        std::sort(fin.begin(), fin.end(), [](const Event& a, const Event& b) { return a.strength > b.strength; });
        fin.resize(o.maxEvents);
        std::sort(fin.begin(), fin.end(), [](const Event& a, const Event& b) { return a.time < b.time; });
    }
    return fin;
}

} // namespace vsbeat

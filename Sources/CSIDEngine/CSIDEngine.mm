#import "include/CSIDEngine.h"

#include <sidplayfp/sidplayfp.h>
#include <sidplayfp/SidTune.h>
#include <sidplayfp/SidTuneInfo.h>
#include <sidplayfp/SidConfig.h>
#include <sidplayfp/SidInfo.h>
#include <sidplayfp/builders/sidlite.h>

#include <cstring>
#include <vector>

@implementation CSIDTuneInfo
@end

@implementation CSIDEngine {
    sidplayfp      *_engine;
    SidTune        *_tune;
    SIDLiteBuilder *_builder;
    std::vector<short> _scratch;     // leftover samples from last play() call
    size_t          _scratchHead;    // next sample to consume from _scratch
    NSInteger       _sampleRate;     // last sample rate passed to startSong
    NSInteger       _currentSong;    // 1-indexed; 0 = nothing started
}

@synthesize currentSong = _currentSong;
@synthesize defaultSidModel = _defaultSidModel;
@synthesize forceSidModel = _forceSidModel;
@synthesize defaultC64Model = _defaultC64Model;
@synthesize forceC64Model = _forceC64Model;
@synthesize digiBoost = _digiBoost;
@synthesize samplingMethod = _samplingMethod;

+ (NSString *)md5ForFileAtPath:(NSString *)path {
    SidTune tune([path UTF8String], nullptr, true);
    if (!tune.getStatus()) return nil;
    char md5buf[SidTune::MD5_LENGTH + 1] = {0};
    const char *m = tune.createMD5New(md5buf);
    return (m && *m) ? @(m) : nil;
}

static NSError *makeError(NSString *msg) {
    return [NSError errorWithDomain:@"CSIDEngine"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"unknown"}];
}

- (instancetype)init {
    if ((self = [super init])) {
        _engine = new sidplayfp();
        _tune = nullptr;
        _builder = nullptr;
        _scratchHead = 0;
        _sampleRate = 0;
        _currentSong = 0;
        _defaultSidModel = CSIDModelUnknown;
        _forceSidModel = NO;
        _defaultC64Model = CSIDClockUnknown;
        _forceC64Model = NO;
        _digiBoost = NO;
        _samplingMethod = CSIDSamplingInterpolate;
    }
    return self;
}

- (void)dealloc {
    if (_engine) _engine->load(nullptr);
    delete _engine;
    delete _tune;
    delete _builder;
}

- (BOOL)loadTuneAtPath:(NSString *)path error:(NSError **)error {
    if (_engine) _engine->load(nullptr);   // detach before deleting
    delete _tune;
    _tune = new SidTune([path UTF8String], nullptr, true);
    if (!_tune->getStatus()) {
        const char *msg = _tune->statusString();
        if (error) *error = makeError(msg ? @(msg) : @"unknown SidTune error");
        delete _tune;
        _tune = nullptr;
        return NO;
    }
    return YES;
}

- (nullable CSIDTuneInfo *)tuneInfo {
    if (!_tune || !_tune->getStatus()) return nil;
    const SidTuneInfo *ti = _tune->getInfo();
    if (!ti) return nil;

    CSIDTuneInfo *out = [CSIDTuneInfo new];
    unsigned ns = ti->numberOfInfoStrings();
    if (ns >= 1 && ti->infoString(0)) out.title    = @(ti->infoString(0));
    if (ns >= 2 && ti->infoString(1)) out.author   = @(ti->infoString(1));
    if (ns >= 3 && ti->infoString(2)) out.released = @(ti->infoString(2));
    if (ti->formatString())            out.format  = @(ti->formatString());

    out.songCount = ti->songs();
    out.startSong = ti->startSong();
    out.sidChips  = ti->sidChips();

    char md5buf[SidTune::MD5_LENGTH + 1] = {0};
    const char *m = _tune->createMD5New(md5buf);
    if (m && *m) out.md5 = @(m);

    switch (ti->clockSpeed()) {
        case SidTuneInfo::CLOCK_PAL:  out.clock = CSIDClockPAL; break;
        case SidTuneInfo::CLOCK_NTSC: out.clock = CSIDClockNTSC; break;
        case SidTuneInfo::CLOCK_ANY:  out.clock = CSIDClockAny; break;
        default:                      out.clock = CSIDClockUnknown; break;
    }
    switch (ti->sidModel(0)) {
        case SidTuneInfo::SIDMODEL_6581: out.model = CSIDModel6581; break;
        case SidTuneInfo::SIDMODEL_8580: out.model = CSIDModel8580; break;
        case SidTuneInfo::SIDMODEL_ANY:  out.model = CSIDModelAny; break;
        default:                         out.model = CSIDModelUnknown; break;
    }
    return out;
}

- (BOOL)startSong:(NSInteger)songNum sampleRate:(NSInteger)sampleRate error:(NSError **)error {
    if (!_tune) {
        if (error) *error = makeError(@"no tune loaded");
        return NO;
    }

    _tune->selectSong((unsigned)songNum);

    if (!_builder) {
        _builder = new SIDLiteBuilder("sidlite");
    }

    SidConfig cfg = _engine->config();
    cfg.frequency    = (uint_least32_t)sampleRate;
    cfg.sidEmulation = _builder;

    // SID model
    if (_forceSidModel) {
        cfg.forceSidModel = true;
        cfg.defaultSidModel = (_defaultSidModel == CSIDModel8580)
            ? SidConfig::MOS8580 : SidConfig::MOS6581;
    } else {
        cfg.forceSidModel = false;
    }

    // C64 model / clock
    if (_forceC64Model) {
        cfg.forceC64Model = true;
        cfg.defaultC64Model = (_defaultC64Model == CSIDClockNTSC)
            ? SidConfig::NTSC : SidConfig::PAL;
    } else {
        cfg.forceC64Model = false;
    }

    cfg.digiBoost = _digiBoost;
    cfg.samplingMethod = (_samplingMethod == CSIDSamplingResample)
        ? SidConfig::RESAMPLE_INTERPOLATE : SidConfig::INTERPOLATE;

    if (!_engine->config(cfg)) {
        if (error) *error = makeError(@(_engine->error() ?: "engine config failed"));
        return NO;
    }
    if (!_engine->load(_tune)) {
        if (error) *error = makeError(@(_engine->error() ?: "engine load failed"));
        return NO;
    }
    _engine->initMixer(false);  // mono

    _scratch.clear();
    _scratchHead = 0;
    _sampleRate = sampleRate;
    _currentSong = songNum;
    return YES;
}

- (BOOL)selectSong:(NSInteger)songNum error:(NSError **)error {
    if (_sampleRate == 0) {
        if (error) *error = makeError(@"selectSong called before startSong:sampleRate:");
        return NO;
    }
    return [self startSong:songNum sampleRate:_sampleRate error:error];
}

- (NSInteger)renderFrames:(int16_t *)buffer count:(NSInteger)frameCount {
    NSInteger written = 0;
    while (written < frameCount) {
        size_t avail = _scratch.size() - _scratchHead;
        if (avail > 0) {
            size_t take = avail < (size_t)(frameCount - written) ? avail : (size_t)(frameCount - written);
            std::memcpy(buffer + written, _scratch.data() + _scratchHead, take * sizeof(int16_t));
            _scratchHead += take;
            written += (NSInteger)take;
            continue;
        }

        // Refill scratch from the engine. ~5000 cycles ≈ 225 samples at PAL/44.1k.
        const unsigned chunkCycles = 5000;
        int produced = _engine->play(chunkCycles);
        if (produced <= 0) break;

        if (_scratch.size() < (size_t)produced) _scratch.resize((size_t)produced);
        unsigned mixed = _engine->mix(_scratch.data(), (unsigned)produced);
        if (mixed == 0) break;

        _scratch.resize(mixed);
        _scratchHead = 0;
    }
    return written;
}

- (NSTimeInterval)currentTime {
    if (!_engine) return 0;
    return (NSTimeInterval)_engine->timeMs() / 1000.0;
}

- (void)setVoiceMuted:(NSInteger)voice muted:(BOOL)muted {
    if (!_engine || voice < 0 || voice > 2) return;
    // libsidplayfp's mute(): enable=true unmutes, enable=false mutes.
    _engine->mute(0, (unsigned)voice, !muted);
}

- (NSInteger)cia1TimerA {
    if (!_engine) return 0;
    return (NSInteger)_engine->getCia1TimerA();
}

- (void)setKernalROM:(NSData *)kernal basicROM:(NSData *)basic chargenROM:(NSData *)chargen {
    if (!_engine) return;
    const uint8_t *k = kernal  ? (const uint8_t *)kernal.bytes  : nullptr;
    const uint8_t *b = basic   ? (const uint8_t *)basic.bytes   : nullptr;
    const uint8_t *c = chargen ? (const uint8_t *)chargen.bytes : nullptr;
    _engine->setRoms(k, b, c);
}

- (void)stop {
    if (_engine) _engine->load(nullptr);
    _scratch.clear();
    _scratchHead = 0;
    _currentSong = 0;
}

@end

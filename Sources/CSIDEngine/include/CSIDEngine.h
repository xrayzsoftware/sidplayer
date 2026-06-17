#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CSIDClock) {
    CSIDClockUnknown = 0,
    CSIDClockPAL,
    CSIDClockNTSC,
    CSIDClockAny,
};

typedef NS_ENUM(NSInteger, CSIDModel) {
    CSIDModelUnknown = 0,
    CSIDModel6581,
    CSIDModel8580,
    CSIDModelAny,
};

typedef NS_ENUM(NSInteger, CSIDSampling) {
    CSIDSamplingInterpolate = 0,
    CSIDSamplingResample,
};

@interface CSIDTuneInfo : NSObject
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *author;
@property (nonatomic, copy, nullable) NSString *released;
@property (nonatomic, copy, nullable) NSString *format;     // "PSID" / "RSID"
@property (nonatomic, copy, nullable) NSString *md5;        // HVSC#68+ MD5 hash
@property (nonatomic, assign) NSInteger songCount;
@property (nonatomic, assign) NSInteger startSong;          // 1-indexed
@property (nonatomic, assign) NSInteger sidChips;
@property (nonatomic, assign) CSIDClock clock;
@property (nonatomic, assign) CSIDModel model;
@end

@interface CSIDEngine : NSObject

/// Cheap MD5 helper that doesn't allocate an engine. Loads the file via SidTune
/// and returns the HVSC#68+ MD5 (the format Songlengths.md5 keys on).
/// Returns nil if the file isn't a valid SID.
+ (nullable NSString *)md5ForFileAtPath:(NSString *)path;

- (instancetype)init;

- (BOOL)loadTuneAtPath:(NSString *)path
                 error:(NSError * _Nullable * _Nullable)error;

- (nullable CSIDTuneInfo *)tuneInfo;

- (BOOL)startSong:(NSInteger)songNum
       sampleRate:(NSInteger)sampleRate
            error:(NSError * _Nullable * _Nullable)error;

/// Switch to a different sub-song, keeping the previously configured sample rate.
/// Resets playback position to zero. Requires startSong:sampleRate: was called first.
- (BOOL)selectSong:(NSInteger)songNum
             error:(NSError * _Nullable * _Nullable)error;

/// Currently selected sub-song (1-indexed). 0 if no song has been started.
@property (nonatomic, readonly) NSInteger currentSong;

/// Emulation configuration. Set before calling startSong:sampleRate:.
@property (nonatomic, assign) CSIDModel defaultSidModel;
@property (nonatomic, assign) BOOL forceSidModel;
@property (nonatomic, assign) CSIDClock defaultC64Model;
@property (nonatomic, assign) BOOL forceC64Model;
@property (nonatomic, assign) BOOL digiBoost;
@property (nonatomic, assign) CSIDSampling samplingMethod;

/// Use the full-quality reSIDfp analog model instead of the lightweight
/// SIDLite core. Applied on the next startSong:. Only reSIDfp's filter responds
/// to the curve settings below.
@property (nonatomic, assign) BOOL useReSIDfp;

/// reSIDfp 6581 / 8580 filter curve: 0.0 (dark) … 1.0 (bright), default 0.5.
/// Ignored by SIDLite. Applied on the next startSong:.
@property (nonatomic, assign) double filter6581Curve;
@property (nonatomic, assign) double filter8580Curve;

/// Renders up to `frameCount` mono int16 frames into `buffer`.
/// Returns frames actually written (0 indicates engine stop / error).
- (NSInteger)renderFrames:(int16_t *)buffer count:(NSInteger)frameCount;

/// Current playback position, seconds since start of the active song.
- (NSTimeInterval)currentTime;

/// Mute / unmute one of the three SID voices (0, 1, or 2). Takes effect
/// immediately. Pass NO to re-enable. Only valid after startSong:.
- (void)setVoiceMuted:(NSInteger)voice muted:(BOOL)muted;

/// Returns the CIA1 Timer A value the tune programmed during init, or 0
/// if VBI-driven. Convertible to a play-rate multiplier of the video frame.
- (NSInteger)cia1TimerA;

/// Fills `outRegs` (must hold 32 bytes) with the last values written to the
/// registers of SID chip `sidNum` (0, 1, or 2) — i.e. the tune's programmed
/// frequency / waveform / ADSR / filter state. Returns NO if that chip doesn't
/// exist (e.g. chip 1 on a single-SID tune). Only meaningful after startSong:.
/// Call from the producer thread, between renderFrames: calls — it reads engine
/// state and must not race a render.
- (BOOL)readRegisters:(uint8_t *)outRegs forSID:(NSInteger)sidNum;

/// Loads C64 system ROMs (KERNAL/BASIC/CHARGEN) into the engine. Required
/// for many RSID tunes that call into KERNAL routines. Pass nil for any
/// ROM you don't have (fewer tunes will work). Each NSData should hold the
/// raw ROM bytes (8192/8192/4096 respectively).
- (void)setKernalROM:(nullable NSData *)kernal
            basicROM:(nullable NSData *)basic
          chargenROM:(nullable NSData *)chargen;

- (void)stop;
@end

NS_ASSUME_NONNULL_END

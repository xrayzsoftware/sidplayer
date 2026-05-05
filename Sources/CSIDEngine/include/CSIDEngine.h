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

/// Renders up to `frameCount` mono int16 frames into `buffer`.
/// Returns frames actually written (0 indicates engine stop / error).
- (NSInteger)renderFrames:(int16_t *)buffer count:(NSInteger)frameCount;

/// Current playback position, seconds since start of the active song.
- (NSTimeInterval)currentTime;

/// Mute / unmute one of the three SID voices (0, 1, or 2). Takes effect
/// immediately. Pass NO to re-enable. Only valid after startSong:.
- (void)setVoiceMuted:(NSInteger)voice muted:(BOOL)muted;

- (void)stop;
@end

NS_ASSUME_NONNULL_END

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
- (instancetype)init;

- (BOOL)loadTuneAtPath:(NSString *)path
                 error:(NSError * _Nullable * _Nullable)error;

- (nullable CSIDTuneInfo *)tuneInfo;

- (BOOL)startSong:(NSInteger)songNum
       sampleRate:(NSInteger)sampleRate
            error:(NSError * _Nullable * _Nullable)error;

/// Renders up to `frameCount` mono int16 frames into `buffer`.
/// Returns frames actually written (0 indicates engine stop / error).
- (NSInteger)renderFrames:(int16_t *)buffer count:(NSInteger)frameCount;

/// Current playback position, seconds since start of the active song.
- (NSTimeInterval)currentTime;

- (void)stop;
@end

NS_ASSUME_NONNULL_END

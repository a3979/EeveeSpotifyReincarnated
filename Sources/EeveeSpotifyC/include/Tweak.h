#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

int MixRebuildInstallPreferenceCapture(void);
id _Nullable MixRebuildObservedPreferenceObject(void);
unsigned int MixRebuildPreferenceCaptureEvents(void);
NSInteger MixRebuildReadNativeCrossfadeTimeOrNeg1(id target);
int MixRebuildReadNativeCrossfadeEnabledOrNeg1(id target);
int MixRebuildReadNativeCrossfade(id target, NSInteger *_Nonnull milliseconds, BOOL *_Nonnull enabled);
void MixRebuildSetNativeCrossfadeTime(id target, NSInteger milliseconds);
void MixRebuildSetNativeCrossfadeEnabled(id target, BOOL enabled);
NSString *MixRebuildDescribeNativeMixClasses(void);
int MixRebuildInstallRegularPlayerObserver(void);
NSString *MixRebuildRegularPlayerStatus(void);
id _Nullable MixRebuildRegularPlayerService(void);
id _Nullable MixRebuildRegularPlayerQueue(void);
id _Nullable MixRebuildRegularPlayerList(void);
id _Nullable MixRebuildRegularLastPlayer(void);
id _Nullable MixRebuildCreateSecondaryPlayer(id service, id viewURI, id featureIdentifier,
                                             id referrerIdentifier, id queue);
id _Nullable MixRebuildCreatePlayerContext(id trackURI);
id _Nullable MixRebuildCreatePlayOptions(BOOL initiallyPaused, double playbackSpeed, double seekToMs);
BOOL MixRebuildPreparePlayer(id player, id context, id options, id viewURI);
BOOL MixRebuildPlayPlayer(id player, id context, id options, id viewURI);
BOOL MixRebuildStopPlayer(id player);
BOOL MixRebuildPromotePlayer(id playerList, id player);
id _Nullable MixRebuildPlayerState(id player);
id _Nullable MixRebuildPlayerTrack(id player);
id _Nullable MixRebuildPlayerTrackURI(id player);
double MixRebuildPlayerPositionMs(id player);
double MixRebuildPlayerDurationMs(id player);
BOOL MixRebuildPlayerIsPlaying(id player);
id _Nullable MixRebuildPlayerLogicalIdentifier(id player);
id _Nullable MixRebuildPlayerViewURI(id player);
id _Nullable MixRebuildPlayerFeatureIdentifier(id player);
id _Nullable MixRebuildPlayerReferrerIdentifier(id player);
id _Nullable MixRebuildQueueForNextTrack(id queue);
id _Nullable MixRebuildTrackURI(id track);
id _Nullable MixRebuildTrackMetadata(id track);
id _Nullable MixRebuildTrackMetadataValue(id track, id key);
id _Nullable MixRebuildQueueNextTrack(id queue);
void MixRebuildArmNextNativePCMSourceMuted(void);
void MixRebuildCancelNextNativePCMSourceMute(void);
uint32_t MixRebuildReadActiveNativePCMSourceIDs(uint32_t *ids, uint32_t capacity);
uint32_t MixRebuildReadRegisteredNativePCMSourceIDs(uint32_t *ids, uint32_t capacity);
void MixRebuildSetNativePCMSourceGain(uint32_t sourceID, float gain);
void MixRebuildResetNativePCMSourceGains(void);
int MixRebuildInstallPlaybackProbe(void);
int MixRebuildActiveNativePCMPaths(void);
int MixRebuildActiveAVFoundationPCMPaths(void);
NSString *MixRebuildPlaybackMonitorStatus(void);
void MixRebuildSetDiagnosticsEnabled(BOOL enabled);
void MixRebuildReadPCMEnvelope(double *values, uint32_t capacity,
                               uint32_t *sampleCount, double *sampleHz);
void EeveeSBInvokeSeekDouble(id target, SEL selector, double argument);
NSString *EeveeJBRootPath(NSString *path);
BOOL EeveeSetMainInfoValue(NSString *key, id value);
UIImage *_Nullable EeveeRenderTemplate(UIView *view);
UIImage *_Nullable EeveeEncoreIconImage(UIView *iconView, BOOL active);
BOOL EeveeFireTap(UIView *root);
int EeveeInstallColorSwaps(BOOL amoled, NSInteger accentRGB);
void EeveeColorSwapStats(long *grey, long *green, long *uiColor);
BOOL EeveePinSetter(id object, SEL setter, id value);
BOOL EeveeInterceptBackground(UIView *view, void (^sink)(UIColor *color));

// Artist-page download button of the Pixie companion. They resolve its exported functions at
// runtime and do nothing when the companion is not loaded.
void EeveePixieUpdateArtistDownloads(UIView *header, UIButton *_Nullable externalButton);
NSString *_Nullable EeveePixieArtistURIForHeader(UIView *header);
void EeveePixieInstallArtistFollow(void);
// The Pixie download manager page in Eevee's settings list. Both do nothing when the companion is not loaded.
BOOL EeveePixieDownloadsAvailable(void);
NSString *EeveePixieStartupSummary(void);
UIViewController *_Nullable EeveePixieMakeDownloadsController(void);
NSInteger EeveePixieArtistFollowing(UIView *header, void (^changed)(void));
// 1 saved, 0 not saved, -1 not known yet. `changed` runs when Spotify reports a new state.
NSInteger EeveePixieSavedState(UIView *page, NSString *uri, void (^changed)(void));

NS_ASSUME_NONNULL_END

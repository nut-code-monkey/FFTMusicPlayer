#import <UIKit/UIKit.h>

@class MPMediaItem;

@protocol FFTMusicPlayerDelegate;

@interface FFTMusicPlayer : NSObject

@property (assign, nonatomic, readonly, getter = isPlayed) BOOL played;

@property (assign, nonatomic, getter = isFftDataValid) BOOL fftDataValid;
@property (assign, nonatomic, getter = isRandom) BOOL random;
@property (assign, nonatomic, getter = isCircle) BOOL circle;

@property (copy, nonatomic) NSArray* queue; // queue of MPMediaItem
@property (strong, nonatomic) MPMediaItem* currentItem;

@property (weak, nonatomic) id<FFTMusicPlayerDelegate> playerDelegate;

+(instancetype)playerWithDelegate:(id<FFTMusicPlayerDelegate>)delegate;

-(void)play;
-(void)stop;
-(void)next;
-(void)previous;

-(void)seek:( CGFloat )seek;

-(float*)mallocFFTBarsWithBarsCount:( NSUInteger )barsCount;

@end


@protocol FFTMusicPlayerDelegate <NSObject>

-(void)player:(FFTMusicPlayer*)player cantCopyMediaItemBecauseDRM:(MPMediaItem*)mediaItem;
-(void)player:(FFTMusicPlayer*)player didStartCopyMediItem:(MPMediaItem*)mediaItem;
-(void)player:(FFTMusicPlayer*)player copyMediItem:(MPMediaItem*)mediaItem withProgress:( CGFloat )percents;
-(void)player:(FFTMusicPlayer*)player didStopCopyMediItem:(MPMediaItem*)mediaItem;

@end
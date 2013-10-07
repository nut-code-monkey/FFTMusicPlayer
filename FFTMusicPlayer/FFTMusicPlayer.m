#import "FFTMusicPlayer.h"

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>

#import "TSLibraryImport.h"
#import <MediaPlayer/MediaPlayer.h>
#import <AssetsLibrary/AssetsLibrary.h>

typedef void(^FFTCopyProgressHandler)(CGFloat progress);

@interface FFTMusicPlayer ()

@property (assign, nonatomic, getter = isPlayed) BOOL played;

@property (assign, nonatomic) FFTSetup fftSetup;
@property (assign, nonatomic) int framesCount;
@property (assign, nonatomic) AudioComponentInstance toneUnit;
@property (assign, nonatomic) float *fftWindow;
@property (assign, nonatomic) DSPSplitComplex fftLeft;
@property (assign, nonatomic) AudioStreamBasicDescription outputAudioFormat;
@property (assign, nonatomic) ExtAudioFileRef sourceAudioFile;

@property (assign, atomic, getter = isCoping) BOOL coping;

@end

@implementation FFTMusicPlayer

@synthesize toneUnit;

+(instancetype)playerWithDelegate:(id<FFTMusicPlayerDelegate>)delegate
{
    return [[self alloc] initWithDelegate:delegate];
}

-(void)dealloc
{
    if (self.fftLeft.realp) free(self.fftLeft.realp);
    if (self.fftLeft.imagp) free(self.fftLeft.imagp);
    free(_fftWindow);
}

-(id)initWithDelegate:(id<FFTMusicPlayerDelegate>)delegate
{
    self = [super init];
    if (self)
    {
        self.playerDelegate = delegate;
        [self initPlayer];
    }
    return self;
}

-(void)setRandom:(BOOL)random
{
    _random = random;
    if ( random )
    {
        NSMutableArray* queue = [self.queue mutableCopy];
        for (NSUInteger i = 0; i < self.queue.count * 2; ++i)
        {
            NSUInteger index1 = arc4random() % queue.count;
            NSUInteger index2 = arc4random() % queue.count;
            if (index1 != index2)
            {
                [queue exchangeObjectAtIndex:index1 withObjectAtIndex:index2];
            }
        }
        self.queue = [NSArray arrayWithArray:queue];
    }
    else
    {
        self.queue = [self.queue sortedArrayUsingComparator:^NSComparisonResult(MPMediaItem* item1, MPMediaItem* item2)
                      {
                          NSString* line1 = [[item1 valueForProperty:MPMediaItemPropertyArtist] stringByAppendingString:[item1 valueForProperty:MPMediaItemPropertyTitle]];
                          NSString* line2 = [[item1 valueForProperty:MPMediaItemPropertyArtist] stringByAppendingString:[item1 valueForProperty:MPMediaItemPropertyTitle]];
                          return [line1 caseInsensitiveCompare:line2];
                      }];
    }
}

-(void)handleProgressWithSession:( AVAssetExportSession* )session progressBlock:( FFTCopyProgressHandler )progress
{
    if (session.status != AVAssetExportSessionStatusCompleted
        && session.status != AVAssetExportSessionStatusFailed
        && session.status != AVAssetExportSessionStatusCancelled)
    {
        progress(session.progress);
        
        double delayInSeconds = 0.1;
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
        dispatch_after(popTime, dispatch_get_main_queue(), ^{ [self handleProgressWithSession:session progressBlock:progress];});
    }
}

- (void)copyMediaItem:( MPMediaItem *)mediaItem
             progress:(void(^)(CGFloat))progressBlock
             complete:(void (^)(NSURL* outURL, NSError* error))completionBlock
{
    AVAsset *theAsset = [AVAsset assetWithURL:[mediaItem valueForProperty:MPMediaItemPropertyAssetURL]];
    
    if ([theAsset hasProtectedContent])
    {
        [self.playerDelegate player:self cantCopyMediaItemBecauseDRM:mediaItem];
        completionBlock(nil, [NSError errorWithDomain:@"123456789" code:0 userInfo:nil]);
        return;
    }
    
    AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:theAsset presetName:AVAssetExportPresetAppleM4A];

    NSString *documentsDirectoryPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *storePath = [documentsDirectoryPath stringByAppendingPathComponent:@"temp.m4a"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:storePath])
    {
        [[NSFileManager defaultManager] removeItemAtPath:storePath error:nil];
    }
    
    exportSession.outputFileType = AVFileTypeAppleM4A;
    exportSession.outputURL = [NSURL fileURLWithPath:storePath];
    
    self.coping = YES;
    [exportSession exportAsynchronouslyWithCompletionHandler:^
     {
         completionBlock(exportSession.outputURL, exportSession.error);
         self.coping = NO;
     }];
    
    while (self.isCoping)
    {
        NSLog(@"copy progress: %1.2f", exportSession.progress);
        progressBlock(exportSession.progress);
        [NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
}

-(void)openFile:( NSURL* )mediaFile completion:( void(^)(FFTMusicPlayer* player, NSError* error) )completion;
{
    NSParameterAssert(mediaFile);
    NSParameterAssert(completion);
    
    OSStatus result = noErr;
    UInt32 size;
    
    result = ExtAudioFileOpenURL((__bridge CFURLRef)mediaFile, &_sourceAudioFile);
    if( result != noErr )
    {
        NSString* error = @"Error in ExtAudioFileOpenURL";
        NSLog(@"ExtAudioFileOpenURL: %@", error);
        completion(self, [NSError errorWithDomain:error code:result userInfo:@{NSLocalizedDescriptionKey:error}]);
        return;
    }
    
    AudioStreamBasicDescription clientFormat;
    size = sizeof( clientFormat );

    result = ExtAudioFileSetProperty(_sourceAudioFile, kExtAudioFileProperty_ClientDataFormat, size, &_outputAudioFormat);
    if( result != noErr )
    {
        NSString* error = [NSString stringWithFormat:@"Error while setting client format in source file: %ld", result];
        NSLog(@"ExtAudioFileSetProperty: %@", error);
        completion(self, [NSError errorWithDomain:error code:result userInfo:@{NSLocalizedDescriptionKey:error}]);
    }
    completion(self, nil);
}

- (void)initPlayer
{
    AudioStreamBasicDescription outputAudioFormat;
    
    // Create the canonical PCM client format.
    memset(&outputAudioFormat, 0, sizeof(outputAudioFormat));
    outputAudioFormat.mSampleRate = 44100.00;
    outputAudioFormat.mFormatID = kAudioFormatLinearPCM;
    outputAudioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    outputAudioFormat.mFramesPerPacket = 1;
    outputAudioFormat.mChannelsPerFrame	= 2;
    outputAudioFormat.mBitsPerChannel = sizeof(short) * 8;
    outputAudioFormat.mBytesPerPacket = sizeof(short) * 2;
    outputAudioFormat.mBytesPerFrame = sizeof(short) * 2;
    self.outputAudioFormat = outputAudioFormat;
    
    AudioComponentDescription defaultOutputDescription;
	defaultOutputDescription.componentType = kAudioUnitType_Output;
	defaultOutputDescription.componentSubType = kAudioUnitSubType_RemoteIO;
	defaultOutputDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
	defaultOutputDescription.componentFlags = 0;
	defaultOutputDescription.componentFlagsMask = 0;
	
	// Get the default playback output unit
	AudioComponent defaultOutput = AudioComponentFindNext(NULL, &defaultOutputDescription);
	NSAssert(defaultOutput, @"Can't find default output");
	
	// Create a new unit based on this that we'll use for output
	OSStatus err = AudioComponentInstanceNew(defaultOutput, &toneUnit);
	NSAssert1(toneUnit, @"Error creating unit: %ld", err);
	
	// Set our tone rendering function on the unit
	AURenderCallbackStruct callback = {playbackCallback, (__bridge void *)(self)};
	err = AudioUnitSetProperty(toneUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback));
	NSAssert1(err == noErr, @"Error setting callback: %ld", err);
    
	err = AudioUnitSetProperty(toneUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &_outputAudioFormat, sizeof(AudioStreamBasicDescription));
    NSAssert1(err == noErr, @"Error setting properties: %ld", err);
}

- (void)closePlayer
{
    ExtAudioFileDispose(_sourceAudioFile);
}

- (void)play
{
	OSStatus result = AudioSessionInitialize(NULL, NULL, NULL, NULL);
	if (result == kAudioSessionNoError)
	{
		UInt32 sessionCategory = kAudioSessionCategory_MediaPlayback;
		AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(sessionCategory), &sessionCategory);
	}
	AudioSessionSetActive(true);
    
    // set preferred buffer size
    Float32 preferredBufferSize = .1; // in seconds
    result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize);
    
    [self initFFT];
    
    AudioUnitInitialize(toneUnit);
    AudioOutputUnitStart(toneUnit);
    self.played = YES;
    
    static dispatch_once_t onceToken;
    static dispatch_queue_t copy_media_item_queue = NULL;
    dispatch_once(&onceToken, ^{
        copy_media_item_queue = dispatch_queue_create("copy media item queue", 0);
    });

    dispatch_async(copy_media_item_queue, ^
    {
        dispatch_async(dispatch_get_main_queue(), ^
        {
            [self.playerDelegate player:self didStartCopyMediItem:self.currentItem];
        });

        __weak id<FFTMusicPlayerDelegate> playerDelegate = self.playerDelegate;
        
        [self copyMediaItem:self.currentItem
                   progress:^(CGFloat progress)
         {
             dispatch_async(dispatch_get_main_queue(), ^
             {
                 [playerDelegate player:self copyMediItem:self.currentItem withProgress:progress];
             });
         }
                   complete:^(NSURL *outURL, NSError *error)
         {
             dispatch_async(dispatch_get_main_queue(), ^
             {
                 [playerDelegate player:self didStopCopyMediItem:self.currentItem];
                 
                 if (!error && outURL)
                 {
                     [self openFile:outURL completion:^(FFTMusicPlayer *player, NSError *error)
                      {
                      }];
                 }
             });
         }];
    });
}

static OSStatus playbackCallback(void* rawPointerToPlayer,
                                 AudioUnitRenderActionFlags* ioActionFlags,
                                 const AudioTimeStamp* inTimeStamp,
                                 UInt32 inBusNumber,
                                 UInt32 inNumberFrames,
                                 AudioBufferList* ioData)
{
    FFTMusicPlayer* player = (__bridge FFTMusicPlayer*) rawPointerToPlayer;
    
    UInt32 framesRead = inNumberFrames * sizeof(UInt32);
    ExtAudioFileRead(player.sourceAudioFile, &framesRead, ioData);
    
    player.framesCount = inNumberFrames;
    
    float* signal = malloc(inNumberFrames*sizeof(float));
    float* bufferMemory = malloc(inNumberFrames*sizeof(float));
    
    DSPSplitComplex Buffer = { bufferMemory, bufferMemory + inNumberFrames/2 };
    
    vDSP_vflt16(ioData->mBuffers[0].mData, 2, signal, 1, inNumberFrames);
    
    float *signalW = malloc(inNumberFrames*sizeof(float));
    
    float f = 1.0 / 32768.0;
    
    vDSP_vmul (signal,1, player.fftWindow,1, signalW, 1, inNumberFrames);
    vDSP_vsmul(signalW, 1, &f, signal, 1, inNumberFrames);
	vDSP_ctoz((DSPComplex *) signal, 2, &Buffer, 1, inNumberFrames/2);
    
    DSPSplitComplex fftLeft = player.fftLeft;
    vDSP_fft_zrop(player.fftSetup, &Buffer, 1, &fftLeft, 1, log2(inNumberFrames), FFT_FORWARD);
    player.fftLeft = fftLeft;

    free(signalW);
    free(signal);
    free(bufferMemory);
    
    player.fftDataValid = YES;
    
    NSLog(@"---");
    
    return noErr;
}

- (void)initFFT
{
    // get actuall buffer size
    Float32 audioBufferSize;
    UInt32 size = sizeof (audioBufferSize);
    AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareIOBufferDuration, &size, &audioBufferSize);
    
    self.framesCount = ceil(_outputAudioFormat.mSampleRate * audioBufferSize);
    
    self.fftSetup = vDSP_create_fftsetup(log2(self.framesCount),kFFTRadix2);
    
    if (_fftLeft.realp) free(_fftLeft.realp);
    if (_fftLeft.imagp) free(_fftLeft.imagp);
    
    DSPSplitComplex fftLeft;
    fftLeft.realp = malloc(sizeof(float)*self.framesCount);
    fftLeft.imagp = malloc(sizeof(float)*self.framesCount);
    
    self.fftLeft = fftLeft;
    
    if (self.fftWindow)
    {
        free(_fftWindow);
    }
    self.fftWindow = malloc(sizeof(float)*self.framesCount);
    vDSP_hamm_window(_fftWindow, self.framesCount, 0);
}

- (float*)mallocFFTBarsWithBarsCount:( NSUInteger )barsCount
{
    float* fftValues = malloc(sizeof(float) * barsCount);
    
    int usefullFramesCount = self.framesCount/2;
    
    for (int bar = 0; bar < barsCount; ++bar)
    {
        float v = 0;
        
        for (int j=bar * usefullFramesCount / barsCount; j < (bar+1) * usefullFramesCount / barsCount; ++j)
        {
            float s = _fftLeft.realp[j] / usefullFramesCount;
            float c = _fftLeft.imagp[j] / usefullFramesCount;
            
            float a = sqrt((s*s+c*c)/2.0);
            
            v += a;
        }
        
        v = v;
        
        float base = 2+500 * bar / barsCount;
        
        v = [self logBase:base value:(1 + v*(base-1))];
        
        // TODO:
        // на симуляторе буфер 512, на девайсе 4096 (иначе бывают фризы).
        // подебить FFT так и не удалось (из-за разного размера окна, FFT выдает разные попугаи... потом надо доделать)
        
        v /= 2;
        v -= 0.01;
        
        fftValues[bar] = v;
    }
    
    return fftValues;
}

- (float) logBase: (float) base value: (float) value
{
    return log10f(value) / log10f(base);
}

-(void)setQueue:(NSArray *)queue
{
    for (MPMediaItem* queueItem in queue)
    {
        NSParameterAssert([queueItem isKindOfClass:[MPMediaItem class]]);
    }
    _queue = queue;
    
    if (![queue containsObject:self.currentItem])
        [self stop];
    
    if (queue.count)
        self.currentItem = queue[0];
}

-(void)stop
{
    self.played = NO;
    AudioOutputUnitStop(toneUnit);
}

-(MPMediaItem*)randomTrack
{
    while ( TRUE )
    {
        MPMediaItem* track = self.queue[ arc4random() % self.queue.count ];
        if ( track != self.currentItem )
            return track;
    }
}

-(void)next
{
    NSUInteger index = [self.queue indexOfObject:self.currentItem];
    ++index;
    if ( index == self.queue.count)
        index = 0;
    
    self.currentItem = self.queue[index];
}

-(void)previous
{
    NSInteger index = [self.queue indexOfObject:self.currentItem];
    --index;
    if ( index < 0 )
        index = self.queue.count - 1;
    
    self.currentItem = self.queue[index];
}

@end

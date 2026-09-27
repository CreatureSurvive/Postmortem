#import <Foundation/Foundation.h>
#import <MetricKit/MetricKit.h>
#import <objc/runtime.h>
#define M(v,u) [[NSMeasurement alloc] initWithDoubleValue:v unit:u]
@interface NSObject (P)
- (instancetype)initWithAppVersion:(NSString *)v withMutipleAppVersions:(BOOL)m withTimeStampBegin:(NSDate *)b withTimeStampEnd:(NSDate *)e;
- (instancetype)initWithCumulativeCPUTimeMeasurement:(id)a withCumulativeCPUInstructions:(id)b;
- (instancetype)initWithPeakMemoryUsageMeasurement:(id)a averageMemoryUsageMeasurement:(id)b;
- (instancetype)initWithForegroundExitData:(id)f backgroundExitData:(id)b;
- (instancetype)initWithNormalAppExitCount:(unsigned long long)a withMemoryResourceLimitExitCount:(unsigned long long)b withCPUResourceLimitExitCount:(unsigned long long)c withBadAccessExitCount:(unsigned long long)d withAbnormalExitCount:(unsigned long long)e withIllegalInstructionExitCount:(unsigned long long)f withAppWatchDogExitCount:(unsigned long long)g;
- (instancetype)initWithNormalAppExitCount:(unsigned long long)a memoryResourceLimitExitCount:(unsigned long long)b cpuResourceLimitExitCount:(unsigned long long)c memoryPressureExitCount:(unsigned long long)d badAccessExitCount:(unsigned long long)e abnormalExitCount:(unsigned long long)f illegalInstructionExitCount:(unsigned long long)g appWatchDogExitCount:(unsigned long long)h cumulativeSuspendedWithLockedFileExitCount:(unsigned long long)i cumulativeBackgroundTaskAssertionTimeoutExitCount:(unsigned long long)j cumulativeBackgroundURLSessionCompletionTimeoutExitCount:(unsigned long long)k cumulativeBackgroundFetchCompletionTimeoutExitCount:(unsigned long long)l;
- (instancetype)initWithCumulativeForegroundTimeMeasurement:(id)a cumulativeBackgroundTimeMeasurement:(id)b cumulativeBackgroundAudioTimeMeasurement:(id)c cumulativeBackgroundLocationTimeMeasurement:(id)d;
- (instancetype)initWithHistogramBucketData:(NSArray *)d;
- (instancetype)initWithBucketStart:(id)s bucketEnd:(id)e bucketCount:(unsigned long long)c;
- (instancetype)initWithAppResponsivenessData:(id)h;
- (instancetype)initWithLaunchTimeData:(id)l withResumeTimeData:(id)r;
- (instancetype)initWithHitchTimeRatio:(id)a perceivedHitchTimeRatio:(id)b;
- (instancetype)initWithCumulativeLogicalWritesMeasurement:(id)a;
- (instancetype)initWithCumulativeWifiUploadMeasurement:(id)a cumulativeWifiDownloadMeasurement:(id)b cumulativeCellularUploadMeasurement:(id)c cumulativeCellularDownloadMeasurement:(id)d;
- (instancetype)initWithMeasurement:(id)m sampleCount:(long long)c standardDeviation:(double)d;
- (instancetype)initWithRegionFormat:(NSString *)r osVersion:(NSString *)o deviceType:(NSString *)d appBuildVersion:(NSString *)b platformArchitecture:(NSString *)p bundleID:(NSString *)bid pid:(int)pid isTestFlightApp:(BOOL)tf;
@end
id hist(double a, double b, double c, NSUnit *u) {
  return @[
    [[NSClassFromString(@"MXHistogramBucket") alloc] initWithBucketStart:M(a,u) bucketEnd:M(b,u) bucketCount:40],
    [[NSClassFromString(@"MXHistogramBucket") alloc] initWithBucketStart:M(b,u) bucketEnd:M(c,u) bucketCount:7]];
}
int main(int argc, char **argv) { @autoreleasepool {
  [MXMetricManager sharedManager];
  NSDate *b = [NSDate dateWithTimeIntervalSince1970:1790000000];
  id p = [[NSClassFromString(@"MXMetricPayload") alloc] initWithAppVersion:@"1.2.0" withMutipleAppVersions:NO withTimeStampBegin:b withTimeStampEnd:[b dateByAddingTimeInterval:86400]];
  NSDictionary *metrics = @{
    @"cpuMetrics": [[NSClassFromString(@"MXCPUMetric") alloc] initWithCumulativeCPUTimeMeasurement:M(250, NSUnitDuration.seconds) withCumulativeCPUInstructions:M(12000000, [[NSUnit alloc] initWithSymbol:@"kiloinstructions"])],
    @"memoryMetrics": [[NSClassFromString(@"MXMemoryMetric") alloc] initWithPeakMemoryUsageMeasurement:M(310000, NSUnitInformationStorage.kilobytes) averageMemoryUsageMeasurement:[[NSClassFromString(@"MXAverage") alloc] initWithMeasurement:M(120000, NSUnitInformationStorage.kilobytes) sampleCount:500 standardDeviation:12.5]],
    @"applicationExitMetrics": [[NSClassFromString(@"MXAppExitMetric") alloc] initWithForegroundExitData:[[NSClassFromString(@"MXForegroundExitData") alloc] initWithNormalAppExitCount:30 withMemoryResourceLimitExitCount:2 withCPUResourceLimitExitCount:0 withBadAccessExitCount:1 withAbnormalExitCount:0 withIllegalInstructionExitCount:0 withAppWatchDogExitCount:3] backgroundExitData:[[NSClassFromString(@"MXBackgroundExitData") alloc] initWithNormalAppExitCount:10 memoryResourceLimitExitCount:0 cpuResourceLimitExitCount:0 memoryPressureExitCount:5 badAccessExitCount:0 abnormalExitCount:0 illegalInstructionExitCount:0 appWatchDogExitCount:0 cumulativeSuspendedWithLockedFileExitCount:1 cumulativeBackgroundTaskAssertionTimeoutExitCount:2 cumulativeBackgroundURLSessionCompletionTimeoutExitCount:0 cumulativeBackgroundFetchCompletionTimeoutExitCount:0]],
    @"applicationTimeMetrics": [[NSClassFromString(@"MXAppRunTimeMetric") alloc] initWithCumulativeForegroundTimeMeasurement:M(3600, NSUnitDuration.seconds) cumulativeBackgroundTimeMeasurement:M(600, NSUnitDuration.seconds) cumulativeBackgroundAudioTimeMeasurement:M(0, NSUnitDuration.seconds) cumulativeBackgroundLocationTimeMeasurement:M(0, NSUnitDuration.seconds)],
    @"applicationLaunchMetrics": [[NSClassFromString(@"MXAppLaunchMetric") alloc] initWithLaunchTimeData:hist(300, 400, 900, NSUnitDuration.milliseconds) withResumeTimeData:hist(50, 60, 200, NSUnitDuration.milliseconds)],
    @"applicationResponsivenessMetrics": [[NSClassFromString(@"MXAppResponsivenessMetric") alloc] initWithAppResponsivenessData:hist(250, 500, 2000, NSUnitDuration.milliseconds)],
    @"animationMetrics": [[NSClassFromString(@"MXAnimationMetric") alloc] initWithHitchTimeRatio:M(4.5, [[NSUnit alloc] initWithSymbol:@"ms per s"]) perceivedHitchTimeRatio:M(2, [[NSUnit alloc] initWithSymbol:@"ms per s"])],
    @"diskIOMetrics": [[NSClassFromString(@"MXDiskIOMetric") alloc] initWithCumulativeLogicalWritesMeasurement:M(52000, NSUnitInformationStorage.kilobytes)],
    @"networkTransferMetrics": [[NSClassFromString(@"MXNetworkTransferMetric") alloc] initWithCumulativeWifiUploadMeasurement:M(1200, NSUnitInformationStorage.kilobytes) cumulativeWifiDownloadMeasurement:M(880000, NSUnitInformationStorage.kilobytes) cumulativeCellularUploadMeasurement:M(10, NSUnitInformationStorage.kilobytes) cumulativeCellularDownloadMeasurement:M(20, NSUnitInformationStorage.kilobytes)],
  };
  [p setValue:[[NSClassFromString(@"MXMetaData") alloc] initWithRegionFormat:@"US" osVersion:@"iPhone OS 18.2 (22C152)" deviceType:@"iPhone16,1" appBuildVersion:@"42" platformArchitecture:@"arm64e" bundleID:@"com.example.demo" pid:1234 isTestFlightApp:NO] forKey:@"metaData"];
  for (NSString *k in metrics) { @try { [p setValue:metrics[k] forKey:k]; } @catch (NSException *e) { printf("set %s failed: %s\n", k.UTF8String, e.reason.UTF8String); } }
  NSData *json = [p JSONRepresentation];
  [json writeToFile:@(argv[1]) atomically:YES];
  printf("%s\n", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
}}
